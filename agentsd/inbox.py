"""Every permission question on the machine, in one place.

The hook (`hooks/notch_hook.py`) connects here, sends one JSON line describing
the tool call, and blocks for one line back. Two sources:

- terminal: a `PermissionRequest` hook in an interactive session. Claude Code
  shows its own dialog at the same time, so the notch is a second place to
  answer, not a gate. When the registry shows the dialog closed, the card goes
  and the hook is told `none`.
- owned: a `PreToolUse` hook in a `claude -p` agent the notch started. There is
  no dialog there, so no answer is a deny.

Hooks also send fire-and-forget `event` lines (turn stopped), which become
`fleet_event` broadcasts the voice backend turns into speech.
"""
import asyncio
import hmac
import json
import os
import time
import uuid
from dataclasses import dataclass, field

from loguru import logger

from agentsd import chat, explain, risk
from agentsd.registry import from_registry
from agentsd.snapshot import project_name
from agentsd.turns import DONE_AFTER_S



# Claude's own multiple-choice question. It isn't asking to be allowed: allowing it
# without a choice leaves it waiting, so it only takes answers, or a no.
QUESTION_TOOL = "AskUserQuestion"


@dataclass
class Pending:
    id: str
    source: str
    session_id: str
    pid: int
    cwd: str
    tool: str
    input: dict
    suggestions: list
    created: float = field(default_factory=time.time)
    # What the agent said before asking, from its transcript.
    why: str = ""
    # Asked for from the card. The question stays open meanwhile.
    explanation: str = ""
    explaining: bool = False
    future: asyncio.Future | None = None
    # Seen the session's dialog up. Only then does it closing mean anything.
    armed: bool = False

    def as_dict(self) -> dict:
        return {
            "id": self.id,
            "source": self.source,
            "sessionId": self.session_id,
            "pid": self.pid,
            "project": project_name(self.cwd) if self.cwd else "",
            "cwd": self.cwd,
            "tool": self.tool,
            "detail": risk.detail(self.tool, self.input),
            "summary": risk.summary(self.tool, self.input),
            "risky": risk.destructive(self.tool, self.input),
            "canAlways": bool(self.suggestions),
            "always": always_label(self.suggestions),
            "why": self.why,
            "explanation": self.explanation,
            "explaining": self.explaining,
            "questions": (self.input.get("questions") or []) if self.tool == QUESTION_TOOL else [],
            "created": int(self.created * 1000),
        }


def always_label(suggestions: list) -> str:
    """What "always" would add, as Claude Code writes rules: `Bash(npm test:*)`."""
    rules = []
    for suggestion in suggestions:
        if not isinstance(suggestion, dict):
            continue
        if suggestion.get("type") == "addDirectories":
            rules += [f"access to {d}" for d in suggestion.get("directories") or []]
            continue
        for rule in suggestion.get("rules") or []:
            tool, content = rule.get("toolName") or "", rule.get("ruleContent") or ""
            if tool:
                rules.append(f"{tool}({content})" if content else tool)
    return ", ".join(rules)


def _alive(pid: int) -> bool:
    if pid <= 0:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class Inbox:
    def __init__(self, host: str, port: int, broadcast, owned_timeout_s: float, terminal_timeout_s: float,
                 helper_pids: set[int] | None = None, token: str = ""):
        self.host = host
        self.port = port
        self._broadcast = broadcast
        self._owned_timeout = owned_timeout_s
        self._terminal_timeout = terminal_timeout_s
        self._pending: dict[str, Pending] = {}
        self._server: asyncio.Server | None = None
        # Set, a hook has to show it: a card is something you'll click on, so
        # not just anything on this machine gets to put one up.
        self._token = token
        # Helper Claude processes, which don't belong on the roster.
        self._helper_pids = helper_pids if helper_pids is not None else set()
        self._busy_since: dict[int, float] = {}
        # How long each agent's last stretch of work ran, for the Stop event
        # that may land just before or just after the tick that saw it end.
        self._last_busy: dict[int, float] = {}

    # ---- lifecycle -------------------------------------------------------

    async def start(self):
        self._server = await asyncio.start_server(self._handle, self.host, self.port)
        logger.info(f"approval inbox listening on {self.host}:{self.port}")

    async def stop(self):
        for p in list(self._pending.values()):
            self._settle(p, "none", "notch shutting down")
        if self._server:
            self._server.close()
            await self._server.wait_closed()

    # ---- what clients see -----------------------------------------------

    def snapshot(self) -> dict:
        rows = sorted(self._pending.values(), key=lambda p: p.created)
        return {"type": "approvals", "list": [p.as_dict() for p in rows]}

    async def _changed(self):
        await self._broadcast(self.snapshot())

    def answer(self, req_id: str, approved: bool, always: bool = False, how: str = "",
               answers: dict | None = None) -> bool:
        pending = self._pending.get(req_id)
        if not pending:
            return False
        if approved and pending.tool == QUESTION_TOOL and not answers:
            logger.info("a yes to a question with no choice in it was ignored")
            return False
        decision = "allow" if approved else "deny"
        self._settle(pending, decision, how, always=always and approved,
                     updated_input={**pending.input, "answers": answers} if answers and approved else None)
        logger.info(f"{decision}{' always' if always else ''} {pending.tool} for {project_name(pending.cwd)} {how}")
        return True

    async def explain(self, req_id: str):
        """Say what a question means, without answering it."""
        pending = self._pending.get(req_id)
        if not pending or pending.explaining or pending.explanation:
            return
        pending.explaining = True
        await self._changed()
        rows = await asyncio.to_thread(chat.chat, pending.cwd, pending.session_id)
        pending.explanation = await explain.explain(
            pending.tool, risk.detail(pending.tool, pending.input), rows, self._helper_pids
        )
        pending.explaining = False
        if req_id in self._pending:
            await self._changed()

    def _settle(self, pending: Pending, decision: str, reason: str, always: bool = False,
                updated_input: dict | None = None):
        if pending.future and not pending.future.done():
            result = {"decision": decision, "reason": reason, "always": always}
            if updated_input:
                result["updatedInput"] = updated_input
            pending.future.set_result(result)

    # ---- keeping cards honest -------------------------------------------

    async def reconcile(self):
        """Drop cards whose question was answered somewhere else, or whose agent died."""
        registry = await asyncio.to_thread(from_registry)
        now = time.time()
        for pid, row in registry.items():
            if row.get("status") == "busy":
                self._busy_since.setdefault(pid, now)
            elif pid in self._busy_since:
                self._last_busy[pid] = now - self._busy_since.pop(pid)

        for pending in list(self._pending.values()):
            if not _alive(pending.pid):
                self._settle(pending, "none", "agent exited")
                continue
            if pending.source != "terminal":
                continue
            status = (registry.get(pending.pid) or {}).get("status")
            if status == "waiting":
                pending.armed = True
            elif pending.armed and status:
                self._settle(pending, "none", "answered in the terminal")

    # ---- the hook socket -------------------------------------------------

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        try:
            raw = await asyncio.wait_for(reader.readline(), timeout=5)
            msg = json.loads(raw or b"{}")
        except (asyncio.TimeoutError, json.JSONDecodeError, ConnectionError) as e:
            logger.warning(f"bad hook line: {e}")
            writer.close()
            return

        if self._token and not hmac.compare_digest(str(msg.get("token") or "").encode(), self._token.encode()):
            logger.warning("a hook line without the token was dropped — scripts/install-hooks.sh updates the hook")
            writer.close()
            return

        if msg.get("kind") == "event":
            writer.close()
            await self._event(msg)
            return

        pending = Pending(
            id=uuid.uuid4().hex[:12],
            source="owned" if msg.get("source") == "owned" else "terminal",
            session_id=msg.get("session_id") or "",
            pid=int(msg.get("pid") or 0),
            cwd=msg.get("cwd") or "",
            tool=msg.get("tool") or "tool",
            input=msg.get("input") or {},
            suggestions=msg.get("suggestions") or [],
            future=asyncio.get_running_loop().create_future(),
        )
        if pending.session_id and pending.cwd:
            pending.why = await asyncio.to_thread(chat.why, pending.cwd, pending.session_id)
        timeout = self._owned_timeout if pending.source == "owned" else self._terminal_timeout
        self._pending[pending.id] = pending
        await self._changed()
        closed = asyncio.create_task(reader.read())
        try:
            done, _ = await asyncio.wait({pending.future, closed}, timeout=timeout, return_when=asyncio.FIRST_COMPLETED)
            if pending.future.done():
                answer = pending.future.result()
            elif closed in done:
                # Hook killed: Claude Code gave up on it, or the session went away.
                answer = None
            else:
                answer = {"decision": "none", "reason": "no answer in time"}
        finally:
            closed.cancel()
            self._pending.pop(pending.id, None)
            await self._changed()

        if answer is None:
            writer.close()
            return
        if answer.get("always"):
            answer["permissions"] = pending.suggestions
        writer.write((json.dumps(answer) + "\n").encode())
        try:
            await writer.drain()
        except ConnectionError:
            pass
        writer.close()

    async def _event(self, msg: dict):
        if msg.get("event") != "stop":
            return
        pid = int(msg.get("pid") or 0)
        started = self._busy_since.pop(pid, None)
        span = time.time() - started if started is not None else self._last_busy.pop(pid, 0.0)
        cwd = msg.get("cwd") or ""
        await self._broadcast(
            {
                "type": "fleet_event",
                "event": "done",
                "sessionId": msg.get("session_id") or "",
                "project": project_name(cwd) if cwd else "",
                "long": span >= DONE_AFTER_S,
            }
        )
