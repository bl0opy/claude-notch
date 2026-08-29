"""Who's running, who has the mic, and where a spoken turn goes.

The notch drives sessions it started and can also talk to sessions it didn't:
those it reaches over the peer socket and reads back from their transcript. Only
the focused agent is ever heard — everything else reports in silently, except a
one-line interjection when it blocks on you or finishes.
"""
import asyncio
from dataclasses import dataclass
from typing import Any

from loguru import logger

from agentsd import paths
from agentsd.peer import Messenger
from agentsd.registry import LiveSession, live_sessions
from agentsd.tail import TranscriptTail
from backend.claude_code import ClaudeCodeSession

Event = tuple[str, dict[str, Any]]


@dataclass
class Owned:
    session: ClaudeCodeSession
    # Claude Code only announces its session id once a turn is under way, but an
    # agent has to be addressable the moment it starts — so it goes by pid until
    # the registry or the stream tells us the real id.
    local_id: str
    session_id: str = ""
    pump: asyncio.Task | None = None

    @property
    def id(self) -> str:
        return self.session_id or self.local_id


class AgentDirector:
    """One focus, many agents."""

    def __init__(self, primary: ClaudeCodeSession, watch_interval_s: float = 1.0):
        # Told whenever the set of agents the notch started changes — only those
        # can be interrupted or approved here, and the shell has to know which.
        self.on_owned_change = None
        self._owned: dict[str, Owned] = {}
        self._primary = primary
        self._events: asyncio.Queue[Event] = asyncio.Queue()
        self._messenger = Messenger()
        self._watch_interval = watch_interval_s
        self._watcher: asyncio.Task | None = None
        self._tail: TranscriptTail | None = None
        self._tail_task: asyncio.Task | None = None
        self._states: dict[str, str] = {}
        self.focused: str | None = None

    # ---- lifecycle -------------------------------------------------------

    async def start(self):
        await self._start_owned(self._primary)
        self._watcher = asyncio.create_task(self._watch())

    async def stop(self):
        for task in (self._watcher, self._tail_task):
            if task:
                task.cancel()
        for owned in self._owned.values():
            if owned.pump:
                owned.pump.cancel()
            await owned.session.stop()

    async def _start_owned(self, session: ClaudeCodeSession) -> Owned:
        if session.proc is None:
            await session.start()
        holder = Owned(session=session, local_id=f"pid:{session.proc.pid}")
        self._owned[holder.local_id] = holder
        if self.focused is None:
            self.focused = holder.id
        holder.pump = asyncio.create_task(self._pump(holder))
        self._announce_owned()
        return holder

    async def start_agent(self, cwd: str) -> None:
        """A new agent in another repo, owned by the notch, mic and all."""
        session = ClaudeCodeSession(
            cwd=cwd,
            model=self._primary.model,
            permission_mode=self._primary.permission_mode,
            system_prompt=self._primary.system_prompt,
            settings=self._primary.settings,
        )
        holder = await self._start_owned(session)
        logger.info(f"started an owned agent in {cwd} ({holder.id})")

    # ---- events ----------------------------------------------------------

    async def _pump(self, holder: Owned):
        async for event in holder.session.stream():
            if event["kind"] == "ready" and event.get("session_id"):
                self._adopt(holder, event["session_id"])
            await self._events.put((holder.id, event))

    def _adopt(self, holder: Owned, session_id: str):
        """Swap an agent's placeholder id for the real one, focus included."""
        if holder.session_id == session_id:
            return
        was = holder.id
        holder.session_id = session_id
        if self.focused == was:
            self.focused = session_id
        self._announce_owned()

    def owned_ids(self) -> list[str]:
        return [o.id for o in self._owned.values()]

    def _announce_owned(self):
        if self.on_owned_change:
            self.on_owned_change(self.owned_ids())

    def _holder(self, agent_id: str | None) -> Owned | None:
        if not agent_id:
            return None
        for owned in self._owned.values():
            if agent_id in (owned.local_id, owned.session_id):
                return owned
        return None

    async def stream(self):
        while True:
            yield await self._events.get()

    # ---- focus and input -------------------------------------------------

    def owns(self, session_id: str | None) -> bool:
        return self._holder(session_id) is not None

    @property
    def focused_session(self) -> ClaudeCodeSession | None:
        owned = self._holder(self.focused)
        return owned.session if owned else None

    def cwd_of(self, session_id: str) -> str:
        owned = self._holder(session_id)
        if owned:
            return owned.session.cwd
        row = self._live(session_id)
        return row.cwd if row else ""

    def focus(self, session_id: str):
        if session_id == self.focused:
            return
        self.focused = session_id
        if self._tail_task:
            self._tail_task.cancel()
            self._tail_task = None
        self._tail = None
        if not self.owns(session_id):
            row = self._live(session_id)
            if row:
                self._tail = TranscriptTail(paths.transcript(row.cwd, session_id))
                self._tail_task = asyncio.create_task(self._read_foreign(session_id))
        logger.info(f"focus: {session_id} ({'owned' if self.owns(session_id) else 'foreign'})")

    async def send_turn(self, text: str) -> str:
        """Route a spoken turn to whoever has the mic. Returns a status word."""
        session = self.focused_session
        if session:
            await session.send_user_text(text)
            return "sent"
        row = self._live(self.focused or "")
        if not row:
            return "gone"
        receipt = await self._messenger.send(row, text)
        await self._events.put((row.session_id, {"kind": "delivery", **receipt.as_dict()}))
        return receipt.status

    async def interrupt(self) -> bool:
        """Only an agent we started can be cut off mid-turn."""
        session = self.focused_session
        if not session:
            return False
        await session.interrupt()
        return True

    # ---- watching everyone else -----------------------------------------

    def _live(self, session_id: str) -> LiveSession | None:
        return next((r for r in live_sessions()[0] if r.session_id == session_id), None)

    async def _read_foreign(self, session_id: str):
        """A focused foreign agent is heard by tailing what it writes down."""
        while True:
            await asyncio.sleep(0.5)
            if not self._tail:
                return
            said, ended = await asyncio.to_thread(self._tail.poll)
            for text in said:
                await self._events.put((session_id, {"kind": "text_delta", "text": text}))
            if ended:
                await self._events.put((session_id, {"kind": "turn_end"}))

    async def _watch(self):
        while True:
            try:
                rows = await asyncio.to_thread(lambda: live_sessions()[0])
                for row in rows:
                    holder = next(
                        (o for o in self._owned.values()
                         if o.session.proc and o.session.proc.pid == row.pid),
                        None,
                    )
                    if holder:
                        self._adopt(holder, row.session_id)
                for receipt in await self._messenger.pump(rows):
                    await self._events.put(
                        (receipt.session_id, {"kind": "delivery", **receipt.as_dict()})
                    )
                for row in rows:
                    self._note(row)
                self._states = {r.session_id: r.state for r in rows}
            except Exception as e:
                logger.warning(f"agent watch tick failed: {e}")
            await asyncio.sleep(self._watch_interval)

    def _note(self, row: LiveSession):
        """One short interjection when a background agent blocks or finishes."""
        was = self._states.get(row.session_id)
        if was is None or was == row.state or row.session_id == self.focused:
            return
        name = row.name or row.cwd.rsplit("/", 1)[-1]
        if row.state == "waiting":
            self._alert(row.session_id, f"{name} needs your ok.")
        elif was == "working" and row.state == "idle":
            self._alert(row.session_id, f"{name} is done.")

    def _alert(self, session_id: str, text: str):
        self._events.put_nowait((session_id, {"kind": "alert", "text": text}))
