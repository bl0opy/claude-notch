"""Smoke test for the supervisor: writes transcripts that look stuck in each of
the ways it knows, and checks what it says about them.

    .venv/bin/python scripts/supervisor_smoke.py          # rules only, no model
    .venv/bin/python scripts/supervisor_smoke.py --live   # also asks Haiku why, via your claude
"""
import asyncio
import json
import os
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

HOME = Path(tempfile.mkdtemp(prefix="supervisor-smoke-"))
os.environ["CLAUDE_HOME"] = str(HOME)
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agentsd import paths  # noqa: E402
from agentsd.supervisor import Supervisor  # noqa: E402

CWD = "/tmp/demo"
failures = 0


def check(label: str, ok: bool, detail: str = ""):
    global failures
    failures += not ok
    print(f"{'ok  ' if ok else 'FAIL'} {label}{f' — {detail}' if detail and not ok else ''}")


def iso(at: float) -> str:
    return datetime.fromtimestamp(at, timezone.utc).isoformat().replace("+00:00", "Z")


class Script:
    """Writes one session's transcript the way Claude Code does."""

    def __init__(self, session_id: str):
        self.id = session_id
        self.path = paths.transcript(CWD, session_id)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.n = 0

    def _row(self, row: dict, at: float):
        with self.path.open("a") as f:
            f.write(json.dumps({**row, "timestamp": iso(at)}) + "\n")

    def prompt(self, text: str, at: float):
        self._row({"type": "user", "message": {"role": "user", "content": text}}, at)

    def say(self, text: str, at: float):
        self._row({"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}}, at)

    def call(self, name: str, args: dict, at: float, failed: bool | None = False, error: str = ""):
        self.n += 1
        tool_id = f"toolu_{self.id}_{self.n}"
        self._row({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": tool_id, "name": name, "input": args}]}}, at)
        if failed is not None:
            self._row({"type": "user", "message": {"content": [
                {"type": "tool_result", "tool_use_id": tool_id, "is_error": failed, "content": error}]}}, at + 1)


def row(session_id: str, state: str = "working") -> dict:
    return {"id": session_id, "cwd": CWD, "project": session_id, "state": state}


async def main() -> int:
    live = "--live" in sys.argv
    events: list[dict] = []

    async def emit(event):
        events.append(event)

    supervisor = Supervisor(emit, explain=live)
    now = time.time()

    def said(session_id: str, kind: str) -> list[str]:
        return [e["line"] for e in events if e["sessionId"] == session_id and e["event"] == kind]

    failing = Script("failing")
    failing.prompt("make the parser tests pass", now - 120)
    failing.call("Edit", {"file_path": "/tmp/demo/parser.py"}, now - 110)
    for i in range(3):
        failing.call("Bash", {"command": "pytest tests/test_parser.py"}, now - 100 + i * 20, failed=True,
                     error="ImportError: cannot import name 'tokenize' from 'demo.lexer'")

    looping = Script("looping")
    looping.prompt("find where the config is loaded", now - 90)
    for i in range(4):
        looping.call("Read", {"file_path": "/tmp/demo/config.py"}, now - 80 + i * 10)

    hung = Script("hung")
    hung.prompt("start the dev server and check the page", now - 500)
    hung.call("Bash", {"command": "npm run dev"}, now - 400, failed=None)

    silent = Script("silent")
    silent.prompt("refactor the router", now - 700)
    silent.say("Let me think about the router's shape.", now - 400)

    churning = Script("churning")
    churning.prompt("fix the layout", now - 200)
    for i in range(8):
        churning.call("Edit", {"file_path": "/tmp/demo/app.css"}, now - 190 + i * 10)

    steady = Script("steady")
    steady.prompt("add a settings page", now - 240)
    steady.call("Write", {"file_path": "/tmp/demo/settings.py"}, now - 230)
    steady.call("Edit", {"file_path": "/tmp/demo/app.py"}, now - 200)
    steady.call("Bash", {"command": "pytest -q"}, now - 150)
    steady.say("Tests pass. Now wiring the settings page into the nav.", now - 100)

    names = ["failing", "looping", "hung", "silent", "churning", "steady"]
    await supervisor.tick([row(n) for n in names], now)
    await asyncio.gather(*supervisor._tasks)

    for name, needle in [
        ("failing", "the same test run has failed 3 times"),
        ("looping", "the same read 4 times"),
        ("hung", "running for 6 minutes"),
        ("silent", "hasn't done anything for 6 minutes"),
        ("churning", "edited the same file 8 times"),
    ]:
        lines = said(name, "stuck")
        if live:
            check(f"{name}: stuck, explained", len(lines) == 1 and lines[0].startswith(f"{name} looks stuck:"), str(lines))
            print(f"       {lines[0] if lines else '—'}")
        else:
            check(f"{name}: stuck", len(lines) == 1 and needle in lines[0], str(lines))

    progress = said("steady", "progress")
    check("steady: a progress line, not stuck", len(progress) == 1 and not said("steady", "stuck"), str(events))
    check(
        "progress line has elapsed, edits, tests and what it's doing",
        progress and all(p in progress[0] for p in ("4 minutes in", "2 edits across 2 files", "tests passing", "wiring the settings page")),
        progress[0] if progress else "",
    )

    before = len(events)
    await supervisor.tick([row(n) for n in names], now + 5)
    await asyncio.gather(*supervisor._tasks)
    check("nothing repeated on the next tick", len(events) == before, str(events[before:]))

    steady.call("Edit", {"file_path": "/tmp/demo/nav.py"}, now + 290)
    await supervisor.tick([row("steady")], now + 305)
    check("the next progress line comes five minutes later", len(said("steady", "progress")) == 2)

    failing.prompt("try a different approach", now + 310)
    await supervisor.tick([row("failing")], now + 320)
    check("a new prompt starts a clean slate", len(said("failing", "stuck")) == 1)
    for i in range(3):
        failing.call("Bash", {"command": "pytest tests/test_parser.py"}, now + 330 + i * 10, failed=True)
    await supervisor.tick([row("failing")], now + 365)
    await asyncio.gather(*supervisor._tasks)
    check("the same failures in the new turn alert again", len(said("failing", "stuck")) == 2)

    idle_before = len(events)
    await supervisor.tick([row("steady", "idle")], now + 2000)
    check("idle agents aren't supervised", len(events) == idle_before)

    print("all good" if not failures else f"{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
