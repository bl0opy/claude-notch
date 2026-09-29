"""Smoke test for typing into a session from the notch, with no voice backend.

Starts an agents daemon on spare ports and a throwaway `claude -p` session, then
sends the daemon a `type` frame the way the notch's compose field does and
checks the session hears it and answers.

    .venv/bin/python scripts/type_smoke.py
"""
import asyncio
import json
import os
import sys
from pathlib import Path

import websockets

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from agentsd.registry import live_sessions  # noqa: E402
from backend.claude_code import ClaudeCodeSession  # noqa: E402

PORTS = {"AGENTS_WS_PORT": "18767", "NOTCH_INBOX_PORT": "18766", "AGENTS_WINDOW_PORT": "18768"}
PROMPT = "Reply with exactly one word: pong"


async def typed(ws, session_id: str, timeout: float = 20) -> dict:
    async with asyncio.timeout(timeout):
        async for raw in ws:
            msg = json.loads(raw)
            if msg.get("type") == "typed" and msg.get("id") == session_id:
                return msg
    return {}


async def main() -> int:
    daemon = await asyncio.create_subprocess_exec(
        sys.executable, "-m", "agentsd",
        cwd=ROOT, env={**os.environ, **PORTS, "SUPERVISOR_EXPLAIN": "off"},
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
    )
    session = ClaudeCodeSession(cwd=".", model="claude-sonnet-5")
    await session.start()
    events = []

    async def drain():
        async for event in session.stream():
            events.append(event)

    task = asyncio.create_task(drain())
    failures = 0
    try:
        await asyncio.sleep(6)
        target = next((r for r in live_sessions()[0] if r.pid == session.proc.pid), None)
        if not target:
            print("FAIL the session never showed up in the registry")
            return 1

        async with websockets.connect(f"ws://127.0.0.1:{PORTS['AGENTS_WS_PORT']}") as ws:
            await ws.send(json.dumps({"type": "type", "id": "no-such-session", "text": "hi"}))
            gone = await typed(ws, "no-such-session")
            ok = gone.get("status") == "gone"
            failures += not ok
            print(f"{'ok  ' if ok else 'FAIL'} an unknown session is gone — {gone}")

            await ws.send(json.dumps({"type": "type", "id": target.session_id, "text": PROMPT}))
            receipt = await typed(ws, target.session_id)
            ok = receipt.get("status") in ("sent", "queued")
            failures += not ok
            print(f"{'ok  ' if ok else 'FAIL'} a terminal session takes the line — {receipt}")

        for _ in range(40):
            await asyncio.sleep(1)
            if any(e["kind"] == "turn_end" for e in events):
                break
        said = "".join(e.get("text", "") for e in events if e["kind"] == "text_delta").strip()
        ok = "pong" in said.lower()
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} it answered — {said[:80]!r}")
    finally:
        task.cancel()
        await session.stop()
        daemon.terminate()
        await daemon.wait()

    print("all good" if not failures else f"{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
