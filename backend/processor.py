import asyncio
import os

from loguru import logger
from pipecat.frames.frames import (
    CancelFrame,
    EndFrame,
    Frame,
    InterruptionFrame,
    LLMFullResponseEndFrame,
    LLMFullResponseStartFrame,
    LLMTextFrame,
    StartFrame,
    TranscriptionFrame,
    UserStartedSpeakingFrame,
)
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from backend.agents import AgentDirector
from backend.bridge import NotchBridge
from backend.commands import Command, parse, spoken_list
from backend.fleet import Fleet
from backend.speech import SpeechFilter
from backend.tools import _TOOL_NARRATION, _tool_detail

# Questions and finishes that land together are said together.
_ALERT_COALESCE_S = 2.0
# Past this, an alert still stuck behind you talking isn't news any more.
_ALERT_STALE_S = 45.0


class ClaudeCodeProcessor(FrameProcessor):
    """Stands where an LLM service normally would.

    Takes final transcriptions in, drives a long-lived Claude Code subprocess,
    and pushes only the speakable prose downstream to TTS. Raw text still goes
    to the notch shell over the bridge.
    """

    def __init__(
        self,
        director: AgentDirector,
        bridge: NotchBridge,
        cancel_on_interrupt: bool,
        fleet: Fleet | None = None,
        max_spoken_sentences: int = 2,
        hold_to_talk: bool = False,
        hold_tail_ms: int = 400,
    ):
        super().__init__()
        self._director = director
        self._bridge = bridge
        self._fleet = fleet
        # (kind, text, approval id) waiting for a quiet moment to be said.
        self._alerts: list[tuple[str, str, str]] = []
        self._alert_task: asyncio.Task | None = None
        self._cancel_on_interrupt = cancel_on_interrupt
        self._filter = SpeechFilter(max_spoken_sentences)
        self._consumer: asyncio.Task | None = None
        self._responding = False
        self._dropping = False
        self._pending_turns = 0
        self._raw = ""
        # The key, not the silence, ends the turn: Flux fires end-of-turn on
        # every pause, so a held key collects those pieces and sends one turn
        # when it comes up. Off when there is no key to hold.
        self._hold_to_talk = hold_to_talk
        self._hold_tail = hold_tail_ms / 1000
        self._mic_open = False
        self._held: list[str] = []
        self._drain: asyncio.Task | None = None

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)

        if isinstance(frame, StartFrame):
            await self.push_frame(frame, direction)
            await self._director.start()
            self._consumer = asyncio.create_task(self._consume())
            await self._bridge.state("listening")
            return

        if isinstance(frame, (EndFrame, CancelFrame)):
            if self._consumer:
                self._consumer.cancel()
            await self._director.stop()
            await self.push_frame(frame, direction)
            return

        if isinstance(frame, (InterruptionFrame, UserStartedSpeakingFrame)):
            await self._handle_interruption()
            await self.push_frame(frame, direction)
            return

        if isinstance(frame, TranscriptionFrame) and frame.text.strip():
            if self._hold_to_talk and (self._mic_open or self._drain):
                self._collect(frame.text)
                await self._bridge.send(
                    {
                        "type": "transcript",
                        "role": "user",
                        "text": " ".join(self._held),
                        "final": False,
                    }
                )
                return
            await self._take_turn(frame.text)
            return

        await self.push_frame(frame, direction)

    # ---- turns -----------------------------------------------------------

    def _collect(self, text: str):
        text = text.strip()
        if text:
            self._held.append(text)

    async def set_mic(self, open_: bool):
        """The push-to-talk key went down or came up.

        Everything Flux hears between the two is one turn, however many pauses
        it took — releasing the key is the only thing that ends it.
        """
        if open_ == self._mic_open:
            return
        self._mic_open = open_
        if not self._hold_to_talk:
            return
        if open_:
            # Pressing again before the tail ran out sends what's held rather
            # than gluing two presses into one turn.
            await self._flush_held()
            return
        # The last words of a hold arrive after the key is already up — Flux
        # only calls end-of-turn once the audio stops — so give them a moment
        # to land before the turn is sealed.
        self._drain = asyncio.create_task(self._drain_held())

    async def _drain_held(self):
        try:
            await asyncio.sleep(self._hold_tail)
        except asyncio.CancelledError:
            return
        self._drain = None
        text = " ".join(self._held).strip()
        self._held = []
        if text:
            await self._take_turn(text)

    async def _flush_held(self):
        """Send whatever is held right now and stop waiting for more."""
        if self._drain:
            self._drain.cancel()
            self._drain = None
        text = " ".join(self._held).strip()
        self._held = []
        if text:
            await self._take_turn(text)

    async def _take_turn(self, text: str):
        if await self._ran_command(text):
            return
        await self._bridge.send(
            {"type": "transcript", "role": "user", "text": text, "final": True}
        )
        await self._bridge.state("thinking")
        self._filter.reset()
        self._raw = ""
        try:
            self._pending_turns += 1
            status = await self._director.send_turn(text)
            if status == "steered":
                # The turn it was in the middle of has been cut off, and that
                # one still owes us a result — which will decrement for it.
                self._dropping = False
            elif status == "queued":
                await self._speak_now("It's mid-turn — I'll pass that on when it's free.")
            elif status == "waiting":
                self._pending_turns = max(0, self._pending_turns - 1)
                await self._speak_now("It's waiting on a permission question — answer that first.")
            elif status == "gone":
                self._pending_turns = max(0, self._pending_turns - 1)
                await self._speak_now("That agent isn't running any more.")
        except Exception as e:
            self._pending_turns -= 1
            logger.error(f"failed to send turn to claude code: {e}")
            await self._bridge.send({"type": "error", "message": str(e)})

    # ---- the fleet -------------------------------------------------------

    async def _ran_command(self, text: str) -> bool:
        """Approvals, focus and status by voice. False when it's a turn for the agent."""
        if not self._fleet:
            return False
        command = parse(text, self._fleet.approvals, self._fleet.agents, self._fleet.totals)
        if not command:
            return False
        await self._bridge.send({"type": "transcript", "role": "user", "text": text, "final": True})
        await self._speak_now(await self._run(command))
        return True

    async def _run(self, command: Command) -> str:
        if command.kind == "answer":
            request = self._fleet.approval(command.id) or {}
            if not await self._fleet.answer(command.id, command.approved, command.always):
                return "I can't reach the agents daemon."
            who = request.get("project") or "it"
            if not command.approved:
                return f"Denied {who}."
            return f"Always allowing that for {who}." if command.always else f"Allowed {who}."
        if command.kind in ("say", "status"):
            return command.text
        if command.kind == "focus":
            await self.focus(command.id)
            return f"You're on {command.text}."
        if command.kind == "home":
            if not self._director.home_id:
                return "I'm not running."
            await self.focus(self._director.home_id)
            return "Back with me."
        if command.kind == "stop":
            if await self._director.interrupt_agent(command.id):
                return f"Stopped {command.text}."
            return f"{command.text} is running in a terminal — I can't stop it from here."
        return ""

    async def focus(self, session_id: str):
        self._director.focus(session_id)
        await self._bridge.send({"type": "focus", "id": session_id})
        await self._bridge.send({"type": "owned", "ids": self._director.owned_ids()})

    async def on_new_approval(self, request: dict):
        project = request.get("project") or "An agent"
        self._alert("ask", f"{project} wants to {request.get('summary') or 'do something'}.", request["id"])

    async def on_fleet_event(self, event: dict):
        # News from agents you aren't talking to: a long turn finishing, the
        # supervisor's progress lines, and one looking stuck. The agent you're
        # focused on you can already hear.
        if event.get("sessionId") == self._director.focused:
            return
        kind = event.get("event")
        if kind == "done" and event.get("long"):
            self._alert("done", event.get("project") or "An agent", "")
        elif kind == "stuck" or (kind == "progress" and event.get("speak")):
            self._alert(kind, event.get("line") or "", "")

    def _alert(self, kind: str, text: str, approval_id: str):
        self._alerts.append((kind, text, approval_id))
        if not self._alert_task:
            self._alert_task = asyncio.create_task(self._say_alerts())

    async def _say_alerts(self):
        try:
            await asyncio.sleep(_ALERT_COALESCE_S)
            waited = 0.0
            # Never over you, and never over an answer being read out.
            while self._mic_open or self._drain or self._responding or self._bridge.last_state == "speaking":
                await asyncio.sleep(0.5)
                waited += 0.5
                if waited > _ALERT_STALE_S:
                    self._alerts = []
                    return
            alerts, self._alerts = self._alerts, []
            line = self._alert_line(alerts)
            if line:
                await self._speak_now(line)
        finally:
            self._alert_task = None
        if self._alerts:
            self._alert_task = asyncio.create_task(self._say_alerts())

    def _alert_line(self, alerts: list[tuple[str, str, str]]) -> str:
        # A question already answered — in the notch, or its terminal — goes unsaid.
        asks = [a for a in alerts if a[0] == "ask" and self._fleet and self._fleet.approval(a[2])]
        done = list(dict.fromkeys(text for kind, text, _ in alerts if kind == "done"))
        stuck = list(dict.fromkeys(text for kind, text, _ in alerts if kind == "stuck"))
        progress = [text for kind, text, _ in alerts if kind == "progress"]
        # Stuck comes first and in full; progress only when nothing louder is
        # queued, and only the newest — it's a status, not a backlog.
        parts = stuck[:2]
        if len(asks) == 1:
            parts.append(asks[0][1])
        elif asks:
            names = list(dict.fromkeys((self._fleet.approval(a[2]) or {}).get("project") or "one" for a in asks))
            parts.append(f"{spoken_list(names)} {'needs' if len(names) == 1 else 'need'} you.")
        if done:
            parts.append(f"{spoken_list(done[:3])} {'is' if len(done) == 1 else 'are'} done.")
        if progress and not parts:
            parts.append(progress[-1])
        return " ".join(parts)

    async def _speak_now(self, text: str):
        """Say something that isn't part of Claude's streamed answer."""
        if not self._responding:
            self._responding = True
            await self.push_frame(LLMFullResponseStartFrame())
        await self.push_frame(LLMTextFrame(text))
        await self.push_frame(LLMFullResponseEndFrame())
        self._responding = False

    async def send_text_turn(self, text: str):
        """Typed input from the notch shell — same path as a spoken turn."""
        await self._take_turn(text)

    async def _handle_interruption(self):
        if not self._responding and not self._dropping:
            return
        self._dropping = True
        self._filter.reset()
        if self._responding:
            await self.push_frame(LLMFullResponseEndFrame())
            self._responding = False
        if self._cancel_on_interrupt:
            await self._director.interrupt()

    async def _speak(self, text: str):
        # A turn we already talked over may still be streaming; only the newest one speaks.
        if self._dropping or self._pending_turns > 1 or not text:
            return
        if not self._responding:
            self._responding = True
            await self.push_frame(LLMFullResponseStartFrame())
            await self._bridge.state("speaking")
        await self.push_frame(LLMTextFrame(text + " "))

    async def _consume(self):
        async for agent_id, event in self._director.stream():
            kind = event["kind"]
            # Everything reaches the notch; only the focused agent is spoken.
            focused = agent_id == self._director.focused

            if kind == "delivery":
                await self._bridge.send({k: v for k, v in event.items() if k != "kind"})
                # A held message that never landed is worth a word — silence
                # here is indistinguishable from having been heard.
                if event.get("status") == "refused":
                    where = os.path.basename(self._director.cwd_of(agent_id)) or "that agent"
                    await self._speak_now(f"Couldn't get that to {where}.")
                continue

            if kind == "ready":
                await self._bridge.send(
                    {
                        "type": "session",
                        "id": event["session_id"],
                        "cwd": self._director.cwd_of(event["session_id"]),
                    }
                )

            elif kind == "turn_start":
                self._raw = ""

            elif kind == "text_delta":
                if self._pending_turns > 1:
                    continue
                await self._bridge.send(
                    {"type": "assistant_delta", "text": event["text"], "agent": agent_id}
                )
                if not focused:
                    continue
                self._raw += event["text"]
                # A foreign agent's deltas are display-only; its answer is
                # spoken whole at turn end instead (backend/agents.py).
                if event.get("speak") is False:
                    continue
                for chunk in self._filter.feed(event["text"]):
                    await self._speak(chunk)

            elif kind == "tool_use":
                name = event["name"]
                verb = _TOOL_NARRATION.get(name, f"using {name}")
                await self._bridge.send(
                    {
                        "type": "tool",
                        "id": event.get("id", ""),
                        "name": name,
                        "summary": verb,
                        "detail": _tool_detail(name, event.get("input") or {}),
                        "agent": agent_id,
                    }
                )

            elif kind == "tool_result":
                await self._bridge.send(
                    {
                        "type": "tool_result",
                        "id": event.get("id", ""),
                        "ok": not event.get("is_error"),
                        "text": event.get("text", ""),
                        "agent": agent_id,
                    }
                )

            elif kind == "turn_end":
                if not focused:
                    continue
                self._pending_turns = max(0, self._pending_turns - 1)
                self._dropping = False
                if self._pending_turns > 0:
                    continue
                answer = (event.get("text") or "").strip()
                if answer:
                    for chunk in self._filter.feed(answer):
                        await self._speak(chunk)
                for chunk in self._filter.flush():
                    await self._speak(chunk)
                if self._responding:
                    await self.push_frame(LLMFullResponseEndFrame())
                    self._responding = False
                await self._bridge.send({"type": "assistant_done", "text": self._raw})
                await self._bridge.state("listening")
                if event.get("is_error"):
                    await self._bridge.send({"type": "error", "message": event.get("text", "")})

            elif kind == "process_exit":
                logger.error("claude code process exited")
                await self._bridge.send({"type": "error", "message": "claude code exited"})
                await self._bridge.state("error")
                break
