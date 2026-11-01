"""What a sandboxed command can do to the notch. Run it from inside Claude Code's
sandbox, against the real daemon. It only knocks: it never sends an answer.

    .venv/bin/python scripts/sandbox_probe.py
"""
import asyncio
import json
import os
from pathlib import Path

import websockets

TOKEN = Path.home() / "Library" / "Application Support" / "notch-agent" / "bridge-token"
PORTS = {"roster": 8767, "voice": 8765, "window": 8768}


async def knock(name: str, port: int, **kwargs):
    path = "/pty/nope" if name == "window" else ""
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}{path}", open_timeout=4, **kwargs):
            print(f"{name:7} OPEN — connected")
    except websockets.InvalidStatus as e:
        print(f"{name:7} refused — HTTP {e.response.status_code}")
    except OSError as e:
        print(f"{name:7} unreachable — {e}")


async def card() -> str:
    try:
        reader, writer = await asyncio.open_connection("127.0.0.1", 8766)
    except OSError as e:
        return f"unreachable — {e}"
    writer.write((json.dumps({"kind": "event", "event": "probe"}) + "\n").encode())
    await writer.drain()
    writer.close()
    return "reachable, line dropped without the token (see the daemon log)"


async def main():
    try:
        print("token file readable:", bool(TOKEN.read_text()))
    except OSError as e:
        print("token file NOT readable:", type(e).__name__)
    print("sandboxed:", os.environ.get("SANDBOX_RUNTIME", "unknown"))
    for name, port in PORTS.items():
        await knock(name, port)
    await knock("roster", PORTS["roster"], origin="http://127.0.0.1:8768")
    print("inbox  ", await card())


asyncio.run(main())
