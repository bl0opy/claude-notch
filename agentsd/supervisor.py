"""Watches the agents you aren't talking to, and says when one is stuck.

Read-only by construction: it is given transcripts and the roster and nothing
else — no pty, no peer socket, no inbox — so it can report on an agent but
never type into, approve for, or interrupt one.

What it reads is the current turn of each working session: every tool call,
whether it failed, which files were edited, and the agent's own last words.
Stuckness is judged from that with plain rules, no model:

- **failing**  the same call has failed three times this turn
- **looping**  the same call, four times in its last dozen, with no edits between
- **hung**     one call has been running for five minutes (a dev server in the
               foreground, a prompt waiting on stdin)
- **silent**   working, but nothing written to its transcript for five minutes
- **churning** the same file edited eight times this turn

A long turn also gets a progress line after three minutes and every five after.

Out goes a `fleet_event` (`progress` or `stuck`) on the roster socket; the
voice backend speaks it and the notch pops it up. For a stuck agent the rule
says *that* it's stuck, and one short tool-less Haiku call through the user's
own `claude` says *why*, in a sentence — no API key, and nothing at all if
`SUPERVISOR_EXPLAIN=off`.
"""
import asyncio
import json
import re
import shutil
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Awaitable, Callable

from loguru import logger

from agentsd import paths
from agentsd.pty_host import session_env
from backend.speech import clean_for_speech

FAIL_REPEATS = 3
LOOP_REPEATS = 4
LOOP_WINDOW = 12
CHURN_EDITS = 8
# Calls that legitimately run long, or that wait on the user by design.
PATIENT_TOOLS = {"Agent", "Task", "AskUserQuestion", "SendMessage", "Monitor"}
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
TEST_COMMAND = re.compile(
    r"\b(pytest|py\.test|unittest|npm (run )?test|yarn test|pnpm test|jest|vitest|go test|"
    r"cargo test|swift test|xcodebuild test|make test|rspec|phpunit|_smoke\.py)\b"
)

EXPLAIN_TIMEOUT_S = 30
# It reads only what it's handed, so it runs somewhere empty: no repo, no
# CLAUDE.md, nothing for its (absent) tools to find.
EXPLAIN_DIR = Path.home() / "Library" / "Application Support" / "notch-agent" / "explainer"
EXPLAIN_PROMPT = (
    "You watch a coding agent work and tell its owner, out loud, why it looks stuck. "
    "Answer in one plain spoken sentence of at most 25 words: what it keeps trying and "
    "what seems to be in the way. No code, no file paths, no commands, no quotes, no "
    "markdown. Your sentence follows the words \"it looks stuck:\", so don't say stuck "
    "again — start with what it keeps doing. If it doesn't actually look stuck, say "
    "briefly what it's doing instead."
)

Emit = Callable[[dict], Awaitable[None]]


def _ts(row: dict) -> float:
    raw = row.get("timestamp")
    if not raw:
        return 0.0
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def _signature(name: str, args: dict) -> str:
    if name == "Bash":
        command = " ".join(str(args.get("command") or "").split())
        return f"Bash:{command.removesuffix(' 2>&1')[:200]}"
    if name in EDIT_TOOLS or name == "Read":
        return f"{name}:{args.get('file_path') or args.get('notebook_path') or ''}"
    return f"{name}:{json.dumps(args, sort_keys=True)[:200]}"


def _result_text(content) -> str:
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        text = " ".join(b.get("text", "") for b in content if isinstance(b, dict))
    else:
        text = ""
    return " ".join(text.split())[:240]


def _prompt_text(content) -> str:
    """The words of a real prompt, or "" for tool results and harness rows."""
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            return ""
        text = " ".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    else:
        return ""
    text = text.strip()
    # Slash-command echoes, reminders and hook output all arrive tagged.
    return "" if not text or text.startswith("<") else text


@dataclass
class Call:
    id: str
    name: str
    sig: str
    detail: str
    at: float
    failed: bool | None = None
    error: str = ""
    done_at: float = 0.0


@dataclass
class Turn:
    started: float = 0.0
    prompt: str = ""
    calls: list[Call] = field(default_factory=list)
    open: dict[str, Call] = field(default_factory=dict)
    edits: dict[str, int] = field(default_factory=dict)
    said: str = ""
    last_row: float = 0.0

    @property
    def tests(self) -> Call | None:
        runs = [c for c in self.calls if c.name == "Bash" and c.failed is not None and TEST_COMMAND.search(c.sig)]
        return runs[-1] if runs else None


class TurnReader:
    """Follows one transcript, keeping only the turn in progress."""

    def __init__(self, path: Path):
        self.path = path
        self.turn = Turn()
        self._offset = 0
        self._carry = b""
        self._inode: int | None = None

    def poll(self) -> Turn:
        try:
            stat = self.path.stat()
        except OSError:
            return self.turn
        if stat.st_ino != self._inode or stat.st_size < self._offset:
            self._inode, self._offset, self._carry, self.turn = stat.st_ino, 0, b"", Turn()
        if stat.st_size == self._offset:
            return self.turn
        with self.path.open("rb") as handle:
            handle.seek(self._offset)
            chunk = handle.read()
        self._offset += len(chunk)
        lines = (self._carry + chunk).split(b"\n")
        self._carry = lines.pop()
        for line in lines:
            try:
                self._row(json.loads(line))
            except (json.JSONDecodeError, AttributeError):
                continue
        return self.turn

    def _row(self, row: dict):
        kind = row.get("type")
        if kind not in ("user", "assistant") or row.get("isSidechain"):
            return
        at = _ts(row) or time.time()
        content = (row.get("message") or {}).get("content")

        if kind == "user":
            prompt = _prompt_text(content)
            if prompt and not row.get("isMeta"):
                self.turn = Turn(started=at, prompt=prompt[:400])
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        call = self.turn.open.pop(block.get("tool_use_id", ""), None)
                        if call:
                            call.failed = bool(block.get("is_error"))
                            call.done_at = at
                            if call.failed:
                                call.error = _result_text(block.get("content"))
            self.turn.last_row = at
            return

        for block in content or []:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text" and block.get("text", "").strip():
                self.turn.said = block["text"].strip()
            elif block.get("type") == "tool_use":
                name = block.get("name") or "tool"
                args = block.get("input") or {}
                call = Call(
                    id=block.get("id", ""),
                    name=name,
                    sig=_signature(name, args),
                    detail=str(args.get("command") or args.get("file_path") or args.get("description") or "")[:160],
                    at=at,
                )
                self.turn.calls.append(call)
                self.turn.open[call.id] = call
                if name in EDIT_TOOLS:
                    path = args.get("file_path") or args.get("notebook_path") or ""
                    self.turn.edits[path] = self.turn.edits.get(path, 0) + 1
        self.turn.last_row = at


@dataclass
class Signal:
    key: str      # one alert per key per turn
    what: str     # the rule's own sentence, used when there's no explanation


def _what(call: Call) -> str:
    if call.name == "Bash":
        return "test run" if TEST_COMMAND.search(call.sig) else "command"
    if call.name in EDIT_TOOLS:
        return "edit"
    return call.name.lower()


def detect(turn: Turn, now: float, hung_s: float, silent_s: float) -> list[Signal]:
    signals = []

    failures: dict[str, list[Call]] = {}
    for call in turn.calls:
        if call.failed:
            failures.setdefault(call.sig, []).append(call)
    for sig, calls in failures.items():
        if len(calls) >= FAIL_REPEATS:
            signals.append(Signal(f"failing:{sig}", f"the same {_what(calls[0])} has failed {len(calls)} times"))

    recent = turn.calls[-LOOP_WINDOW:]
    if not any(c.name in EDIT_TOOLS for c in recent):
        counts: dict[str, int] = {}
        for call in recent:
            counts[call.sig] = counts.get(call.sig, 0) + 1
        for sig, n in counts.items():
            if n >= LOOP_REPEATS and not any(s.key == f"failing:{sig}" for s in signals):
                call = next(c for c in recent if c.sig == sig)
                signals.append(Signal(f"looping:{sig}", f"it's run the same {_what(call)} {n} times without changing anything"))

    for call in turn.open.values():
        if call.name not in PATIENT_TOOLS and now - call.at >= hung_s:
            minutes = int((now - call.at) // 60)
            signals.append(Signal(f"hung:{call.id}", f"one {_what(call)} has been running for {minutes} minutes"))

    if not turn.open and turn.last_row and now - turn.last_row >= silent_s:
        minutes = int((now - turn.last_row) // 60)
        signals.append(Signal(f"silent:{int(turn.last_row)}", f"it hasn't done anything for {minutes} minutes"))

    for path, n in turn.edits.items():
        if n >= CHURN_EDITS:
            signals.append(Signal(f"churning:{path}", f"it's edited the same file {n} times"))
    return signals


def _minutes(seconds: float) -> str:
    m = int(seconds // 60)
    return "a minute" if m <= 1 else f"{m} minutes"


def _last_sentence(text: str) -> str:
    """Where its commentary ends is what it's doing now: "…Now wiring the nav." """
    sentences = [s for s in re.split(r"(?<=[.!?])\s+", clean_for_speech(text)) if s]
    sentence = sentences[-1] if sentences else ""
    return sentence if len(sentence) <= 110 else sentence[:107].rsplit(" ", 1)[0] + "…"


def progress_line(project: str, turn: Turn, now: float) -> str:
    parts = [f"{project}, {_minutes(now - turn.started)} in"]
    files = [p for p in turn.edits if p]
    if files:
        edits = sum(turn.edits.values())
        parts.append(f"{edits} edit{'s' if edits != 1 else ''} across {len(files)} file{'s' if len(files) != 1 else ''}")
    tests = turn.tests
    if tests:
        parts.append("tests failing" if tests.failed else "tests passing")
    line = ", ".join(parts) + "."
    now_doing = _last_sentence(turn.said) if turn.said else ""
    return f"{line} {now_doing}".strip()


def evidence(turn: Turn, now: float) -> str:
    """What the explainer is shown: the ask, then the last stretch of calls."""
    lines = [f"The agent was asked: {turn.prompt}", "", "Its most recent actions, oldest first:"]
    for call in turn.calls[-24:]:
        age = int(now - call.at)
        outcome = "still running" if call.failed is None else ("FAILED" if call.failed else "ok")
        line = f"- {call.name} {call.detail} [{outcome}, {age}s ago]"
        if call.error:
            line += f" error: {call.error[:200]}"
        lines.append(line)
    if turn.said:
        lines += ["", f"The last thing it said: {turn.said[:400]}"]
    return "\n".join(lines)


@dataclass
class Watch:
    reader: TurnReader
    turn_started: float = 0.0
    fired: set[str] = field(default_factory=set)
    last_digest: float = 0.0


class Supervisor:
    def __init__(
        self,
        emit: Emit,
        explain: bool = True,
        digest_after_s: float = 180,
        digest_every_s: float = 300,
        hung_s: float = 300,
        silent_s: float = 300,
        speak_progress: bool = True,
    ):
        self._emit = emit
        self._explain = explain and shutil.which("claude") is not None
        self._digest_after = digest_after_s
        self._digest_every = digest_every_s
        self._hung = hung_s
        self._silent = silent_s
        self._speak_progress = speak_progress
        self._watches: dict[str, Watch] = {}
        self._tasks: set[asyncio.Task] = set()
        # The explainer is a Claude Code process too; it has no business in the roster.
        self.own_pids: set[int] = set()

    async def tick(self, rows: list[dict], now: float | None = None):
        now = time.time() if now is None else now
        working = [r for r in rows if r.get("state") == "working"]
        live = {r["id"] for r in rows}
        for gone in set(self._watches) - live:
            del self._watches[gone]
        for row in working:
            watch = self._watches.get(row["id"])
            if not watch:
                watch = Watch(TurnReader(paths.transcript(row["cwd"], row["id"])))
                self._watches[row["id"]] = watch
            turn = await asyncio.to_thread(watch.reader.poll)
            if not turn.started:
                continue
            if turn.started != watch.turn_started:
                watch.turn_started, watch.fired, watch.last_digest = turn.started, set(), 0.0
            await self._judge(row, watch, turn, now)

    async def _judge(self, row: dict, watch: Watch, turn: Turn, now: float):
        project = row.get("project") or "An agent"
        fresh = [s for s in detect(turn, now, self._hung, self._silent) if s.key not in watch.fired]
        if fresh:
            watch.fired.update(s.key for s in fresh)
            # A stuck agent gets one alert per turn per reason, and the digests
            # stop while it is: saying "nine minutes in" about a loop is noise.
            watch.last_digest = now
            self._spawn(self._stuck(row, project, fresh[0], turn, now))
            return

        elapsed = now - turn.started
        due = watch.last_digest + self._digest_every if watch.last_digest else turn.started + self._digest_after
        if elapsed >= self._digest_after and now >= due:
            watch.last_digest = now
            await self._emit(
                {
                    "type": "fleet_event",
                    "event": "progress",
                    "sessionId": row["id"],
                    "project": project,
                    "line": progress_line(project, turn, now),
                    "level": "info",
                    "speak": self._speak_progress,
                }
            )

    def _spawn(self, coro):
        task = asyncio.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _stuck(self, row: dict, project: str, signal: Signal, turn: Turn, now: float):
        why = await self._why(turn, now) if self._explain else ""
        line = f"{project} looks stuck: {why or signal.what}."
        logger.info(f"supervisor: {line} ({signal.key[:80]})")
        await self._emit(
            {
                "type": "fleet_event",
                "event": "stuck",
                "sessionId": row["id"],
                "project": project,
                "line": line,
                "reason": signal.key.split(":", 1)[0],
                "level": "attention",
                "speak": True,
            }
        )

    async def _why(self, turn: Turn, now: float) -> str:
        argv = [
            "claude", "-p",
            "--model", "haiku",
            "--no-session-persistence",
            "--restricted", "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
            "--system-prompt", EXPLAIN_PROMPT,
        ]
        try:
            EXPLAIN_DIR.mkdir(parents=True, exist_ok=True)
            proc = await asyncio.create_subprocess_exec(
                *argv,
                cwd=EXPLAIN_DIR,
                env=session_env(),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
        except OSError as e:
            logger.warning(f"supervisor: explainer didn't start ({e})")
            return ""
        self.own_pids.add(proc.pid)
        try:
            out, _ = await asyncio.wait_for(
                proc.communicate(evidence(turn, now).encode()), timeout=EXPLAIN_TIMEOUT_S
            )
        except asyncio.TimeoutError:
            proc.kill()
            logger.warning("supervisor: explainer timed out")
            return ""
        finally:
            self.own_pids.discard(proc.pid)
        if proc.returncode != 0:
            return ""
        sentence = clean_for_speech(out.decode(errors="replace")).strip().rstrip(".")
        # Folded into "<project> looks stuck: …", so it starts lower-case.
        return sentence[:1].lower() + sentence[1:] if sentence else ""
