"""End-to-end check of focus routing, without audio.

Starts an owned agent, talks to it, then starts a second session, focuses that
one as if it were a terminal session, talks to it over the peer socket and reads
its answer back out of its transcript — the same path the voice takes.

    .venv/bin/python scripts/director_smoke.py
"""
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agentsd.registry import live_sessions
from backend.agents import AgentDirector
from backend.claude_code import ClaudeCodeSession

REPO = str(Path(__file__).resolve().parent.parent)


async def collect(director, seconds: float) -> list[tuple[str, dict]]:
    events = []

    async def drain():
        async for item in director.stream():
            events.append(item)

    task = asyncio.create_task(drain())
    await asyncio.sleep(seconds)
    task.cancel()
    return events


async def main() -> int:
    primary = ClaudeCodeSession(cwd=REPO, model="claude-sonnet-5")
    director = AgentDirector(primary)
    await director.start()

    await collect(director, 8)
    print(f"owned agent focused as {director.focused and director.focused[:8]}")

    print("status:", await director.send_turn("Reply with exactly one word: alpha"))
    events = await collect(director, 25)
    said = "".join(e.get("text", "") for a, e in events if e["kind"] == "text_delta")
    print("owned said:", repr(said.strip()[:80]))

    # A second session the director did not start, focused as a foreign one.
    foreign = ClaudeCodeSession(cwd=REPO, model="claude-sonnet-5")
    await foreign.start()
    asyncio.create_task(anext_forever(foreign))
    await asyncio.sleep(8)
    # Its own id isn't known until it takes a turn; the registry knows it by pid.
    foreign_id = next(
        (r.session_id for r in live_sessions()[0] if r.pid == foreign.proc.pid), ""
    )
    print("foreign session:", foreign_id and foreign_id[:8])

    director.focus(foreign_id)
    print("routing:", "peer" if not director.owns(foreign_id) else "owned")
    print("status:", await director.send_turn("Reply with exactly one word: beta"))

    events = await collect(director, 30)
    heard = "".join(e.get("text", "") for a, e in events if a == foreign_id and e["kind"] == "text_delta")
    print("foreign said (via transcript tail):", repr(heard.strip()[:80]))

    await director.stop()
    await foreign.stop()
    return 0 if said.strip() and heard.strip() else 1


async def anext_forever(session):
    async for _ in session.stream():
        pass


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
