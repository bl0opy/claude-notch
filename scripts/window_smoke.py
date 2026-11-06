"""Smoke test for the hosted ptys and the terminal window's server.

Runs a stand-in for `claude` (a small echo loop) in a pty, then drives it over
the window's websocket the way the page does: replay, typing, resize, exit.
Also checks that a browser page from anywhere else is turned away.

    .venv/bin/python scripts/window_smoke.py
"""
import asyncio
import json
import os
import sys
import tempfile
import urllib.request
from pathlib import Path
from urllib.parse import quote

import websockets

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
os.environ["NOTCH_TOKEN_FILE"] = str(Path(tempfile.mkdtemp()) / "token")

from agentsd.pty_host import PtyHost
from backend import auth
from agentsd.window import WindowServer

PORT = 18768
FAKE_CLAUDE = r"""
import os, shutil, signal, sys
def size(*_):
    c, r = shutil.get_terminal_size()
    print(f"size {c}x{r} tty={os.isatty(0)}", flush=True)
signal.signal(signal.SIGWINCH, size)
print("ready", " ".join(sys.argv[1:]), flush=True)
size()
for line in sys.stdin:
    if line.strip() == "quit":
        break
    print(f"got:{line.strip()}", flush=True)
"""

failures = 0


def check(label: str, ok: bool, detail: str = ""):
    global failures
    failures += not ok
    print(f"{'ok  ' if ok else 'FAIL'} {label}{f' — {detail}' if detail and not ok else ''}")


def get(path: str) -> tuple[int, bytes]:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}{path}") as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, b""


async def read_until(ws, needle: str, timeout: float = 5) -> str:
    seen = ""
    try:
        async with asyncio.timeout(timeout):
            while needle not in seen:
                frame = json.loads(await ws.recv())
                seen += frame.get("data") or f"[{frame['type']} {frame.get('code')}]"
    except TimeoutError:
        pass
    return seen


async def main() -> int:
    host = PtyHost(argv=[sys.executable, "-c", FAKE_CLAUDE], state_file=None)
    server = WindowServer("127.0.0.1", PORT, host, "ws://127.0.0.1:8767")
    await server.start()
    hosted = host.spawn(".", cols=90, rows=20)
    url = f"ws://127.0.0.1:{PORT}/pty/{hosted.id}"
    await asyncio.sleep(0.5)

    signed = {"additional_headers": auth.headers()}
    try:
        async with websockets.connect(url):
            check("no token, no keyboard", False, "handshake accepted")
    except websockets.InvalidStatus as e:
        check("no token, no keyboard", e.response.status_code == 401, str(e))

    async with websockets.connect(url, **signed) as ws:
        seen = await read_until(ws, "size 90x20")
        check("replay has the first screen", "ready --session-id" in seen and "size 90x20" in seen, seen)
        check("child has a controlling tty", "tty=True" in seen, seen)

        await ws.send(json.dumps({"type": "in", "data": "hello\r"}))
        check("keys reach the pty", "got:hello" in await read_until(ws, "got:hello"))

        await ws.send(json.dumps({"type": "resize", "cols": 132, "rows": 40}))
        check("resize sends SIGWINCH", "size 132x40" in await read_until(ws, "size 132x40"))

        await host.type(hosted.id, "spoken   words\nhere")
        check("type() submits one line", "got:spoken words here" in await read_until(ws, "got:spoken"))

    async with websockets.connect(url, **signed) as late:
        seen = await read_until(late, "got:spoken")
        check("a late window gets the scrollback", "got:hello" in seen, seen)

        host.write(hosted.id, "quit\r")
        check("exit reaches the window", "[exit 0]" in await read_until(late, "[exit"))
    check("session is listed as stopped", not host.snapshot()["list"][0]["running"])

    try:
        async with websockets.connect(url, origin="http://evil.example", **signed):
            check("foreign origin refused", False, "handshake accepted")
    except websockets.InvalidStatus as e:
        check("foreign origin refused", e.response.status_code == 403, str(e))

    try:
        async with websockets.connect(url, origin=f"http://127.0.0.1:{PORT}"):
            check("the right origin isn't enough", False, "handshake accepted")
    except websockets.InvalidStatus as e:
        check("the right origin isn't enough", e.response.status_code == 401, str(e))

    async with websockets.connect(f"{url}?token={quote(auth.token())}", origin=f"http://127.0.0.1:{PORT}") as ws:
        check("the page's own origin with the token is let in", "got:hello" in await read_until(ws, "got:hello"))

    # The server shares this loop, so blocking HTTP has to go to a thread.
    config = await asyncio.to_thread(get, "/config.json")
    check("config.json names the roster", json.loads(config[1])["roster"] == "ws://127.0.0.1:8767")
    check("config.json doesn't give the token away", auth.token().encode() not in config[1])
    check("no escaping the page dir", (await asyncio.to_thread(get, "/../agentsd/config.py"))[0] == 404)

    await server.stop()
    print("all good" if not failures else f"{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
