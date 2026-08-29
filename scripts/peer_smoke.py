"""Smoke test for agentsd.peer: start a session, message it over its socket, hear back.

Starts its own throwaway `claude -p` session so nothing you're working in is
touched, sends it one word over the peer socket, and prints what came back.

    .venv/bin/python scripts/peer_smoke.py
"""
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agentsd.peer import Messenger
from agentsd.registry import live_sessions
from backend.claude_code import ClaudeCodeSession

PROMPT = "Reply with exactly one word: pong"


async def main() -> int:
    session = ClaudeCodeSession(cwd=".", model="claude-sonnet-5")
    await session.start()

    events = []

    async def drain():
        async for event in session.stream():
            events.append(event)

    task = asyncio.create_task(drain())
    await asyncio.sleep(6)

    target = next((r for r in live_sessions()[0] if r.pid == session.proc.pid), None)
    if not target:
        print("FAIL: the session never showed up in the registry")
        return 1
    print(f"target {target.session_id[:8]} state={target.state} socket={bool(target.socket_path)}")

    receipt = await Messenger().send(target, PROMPT)
    print("receipt:", receipt.as_dict())

    for _ in range(40):
        await asyncio.sleep(1)
        if any(e["kind"] == "turn_end" for e in events):
            break

    said = "".join(e.get("text", "") for e in events if e["kind"] == "text_delta").strip()
    task.cancel()
    await session.stop()

    print("heard back:", repr(said[:200]))
    return 0 if said else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
