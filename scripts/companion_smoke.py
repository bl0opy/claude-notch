"""Smoke test for what the notch reads about the sessions it watches.

Starts an agents daemon on spare ports over a fake ~/.claude with one session
in it, then checks the roster row, the session's chat, and that a permission
question carries what the agent said before asking.

    .venv/bin/python scripts/companion_smoke.py
"""
import asyncio
import json
import os
import sys
import tempfile
from pathlib import Path

import websockets

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

PORTS = {"AGENTS_WS_PORT": "18777", "NOTCH_INBOX_PORT": "18776", "AGENTS_WINDOW_PORT": "18778"}
SESSION = "11111111-2222-3333-4444-555555555555"
HOST_SESSION = "local_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
failures = 0


def check(label: str, ok: bool, detail=""):
    global failures
    failures += not ok
    print(f"{'ok  ' if ok else 'FAIL'} {label}{f' — {detail}' if detail and not ok else ''}")


def fake_home(cwd: str) -> tuple[Path, Path]:
    home = Path(tempfile.mkdtemp(prefix="companion-smoke-"))
    (home / "sessions").mkdir()
    (home / "sessions" / f"{os.getpid()}.json").write_text(json.dumps({
        "pid": os.getpid(), "sessionId": SESSION, "cwd": cwd, "status": "busy",
        "entrypoint": "claude-desktop", "hostSessionId": HOST_SESSION, "name": "Smoke test",
    }))
    project = home / "projects" / cwd.replace("/", "-").replace(".", "-")
    project.mkdir(parents=True)
    rows = [
        {"type": "user", "message": {"role": "user", "content": "tidy up the build folder"}},
        {"type": "assistant", "message": {"content": [{"type": "text", "text": "The build folder has stale artifacts from the old target. Clearing them first."}]}},
        {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "rm -r build/old"}}]}},
        {"type": "user", "isMeta": True, "message": {"role": "user", "content": "<system-reminder>noise</system-reminder>"}},
    ]
    (project / f"{SESSION}.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n")

    app = home / "app" / "a" / "b"
    app.mkdir(parents=True)
    (app / f"{HOST_SESSION}.json").write_text(json.dumps({
        "sessionId": HOST_SESSION, "title": "Tidy the build", "permissionMode": "default",
        "postTurnSummary": {"status_detail": "cleared stale artifacts", "needs_action": ""},
    }))
    return home, home / "app"


async def frames(ws, kind: str, timeout: float = 8):
    async with asyncio.timeout(timeout):
        async for raw in ws:
            msg = json.loads(raw)
            if msg.get("type") == kind:
                yield msg


async def first(ws, kind: str, when=lambda m: True) -> dict:
    async for msg in frames(ws, kind):
        if when(msg):
            return msg
    return {}


async def main() -> int:
    cwd = tempfile.mkdtemp(prefix="companion-cwd-")
    home, app = fake_home(cwd)
    env = {**os.environ, **PORTS, "CLAUDE_HOME": str(home), "CLAUDE_DESKTOP_SESSIONS": str(app),
           "SUPERVISOR_EXPLAIN": "off", "PATH": "/usr/bin:/bin"}
    daemon = await asyncio.create_subprocess_exec(
        sys.executable, "-m", "agentsd", cwd=ROOT, env=env,
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
    )
    try:
        await asyncio.sleep(2.5)
        async with websockets.connect(f"ws://127.0.0.1:{PORTS['AGENTS_WS_PORT']}", max_size=None) as ws:
            roster = await first(ws, "agents", lambda m: m.get("list"))
            row = (roster.get("list") or [{}])[0]
            check("a desktop session is shown as one", row.get("host") == "desktop", row)
            check("with the app's title and last summary",
                  row.get("title") == "Tidy the build" and row.get("summary") == "cleared stale artifacts", row)
            check("and a link that opens it in the app",
                  row.get("link") == f"claude://code/continue?session={HOST_SESSION}", row.get("link"))

            await ws.send(json.dumps({"type": "chat", "id": SESSION}))
            chat = await first(ws, "chat")
            roles = [r["role"] for r in chat.get("rows", [])]
            check("its chat: you, claude, the tool, no reminders", roles == ["you", "claude", "tool"], chat)

            reader, writer = await asyncio.open_connection("127.0.0.1", int(PORTS["NOTCH_INBOX_PORT"]))
            writer.write((json.dumps({
                "kind": "permission", "source": "terminal", "session_id": SESSION, "cwd": cwd,
                "pid": os.getpid(), "tool": "Bash", "input": {"command": "rm -r build/old"},
                "suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "rm -r build/*"}],
                                 "behavior": "allow", "destination": "localSettings"}],
            }) + "\n").encode())
            await writer.drain()
            approvals = await first(ws, "approvals", lambda m: m.get("list"))
            card = approvals["list"][0]
            check("a question says why", card.get("why", "").startswith("The build folder has stale artifacts"), card)
            check("and what always would allow", card.get("always") == "Bash(rm -r build/*)", card)

            await ws.send(json.dumps({"type": "approve", "id": card["id"], "approved": False,
                                      "how": "say why first"}))
            line = await asyncio.wait_for(reader.readline(), timeout=5)
            answer = json.loads(line)
            check("ask goes back to the agent as a deny with your question",
                  answer.get("decision") == "deny" and answer.get("reason") == "say why first", answer)
            writer.close()
    finally:
        daemon.terminate()
        await daemon.wait()

    print("all good" if not failures else f"{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
