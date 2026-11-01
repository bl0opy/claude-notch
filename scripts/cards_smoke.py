"""Smoke test for notch_ask and notch_show: the real MCP server, over stdio, to a
daemon on spare ports, with this script playing the notch.

    .venv/bin/python scripts/cards_smoke.py
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
os.environ["NOTCH_TOKEN_FILE"] = str(Path(tempfile.mkdtemp()) / "token")
from backend import auth  # noqa: E402

PORTS = {"AGENTS_WS_PORT": "18787", "NOTCH_INBOX_PORT": "18786", "AGENTS_WINDOW_PORT": "18788"}
failures = 0


def check(label: str, ok: bool, detail=""):
    global failures
    failures += not ok
    print(f"{'ok  ' if ok else 'FAIL'} {label}{f' — {detail}' if detail and not ok else ''}")


class Server:
    def __init__(self, env):
        self.env, self.next_id, self.proc = env, 0, None

    async def start(self):
        self.proc = await asyncio.create_subprocess_exec(
            "/usr/bin/python3", str(ROOT / "hooks" / "notch_mcp.py"), env=self.env,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        )

    def send(self, method: str, params=None) -> int:
        self.next_id += 1
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params or {}}) + "\n").encode())
        return self.next_id

    def cancel(self, request_id: int):
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": request_id}}) + "\n").encode())

    async def reply(self, timeout: float = 8) -> dict:
        return json.loads(await asyncio.wait_for(self.proc.stdout.readline(), timeout))

    async def call(self, name: str, arguments: dict) -> dict:
        self.send("tools/call", {"name": name, "arguments": arguments})
        return (await self.reply())["result"]


async def first(ws, when) -> dict:
    async with asyncio.timeout(8):
        async for raw in ws:
            msg = json.loads(raw)
            if msg.get("type") == "cards" and when(msg["list"]):
                return msg
    return {}


async def main() -> int:
    home = Path(tempfile.mkdtemp(prefix="cards-smoke-"))
    (home / "sessions").mkdir()
    env = {**os.environ, **PORTS, "CLAUDE_HOME": str(home), "SUPERVISOR_EXPLAIN": "off",
           "PATH": "/usr/bin:/bin", "HOME": str(home)}
    daemon = await asyncio.create_subprocess_exec(
        sys.executable, "-m", "agentsd", cwd=ROOT, env=env,
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
    )
    server = Server(env)
    await server.start()
    try:
        await asyncio.sleep(2.5)
        server.send("initialize", {"protocolVersion": "2025-06-18"})
        hello = await server.reply()
        check("it says hello", hello["result"]["serverInfo"]["name"] == "notch")
        server.send("tools/list")
        names = [t["name"] for t in (await server.reply())["result"]["tools"]]
        check("it offers the two tools", names == ["notch_ask", "notch_show"], names)

        async with websockets.connect(f"ws://127.0.0.1:{PORTS['AGENTS_WS_PORT']}", additional_headers=auth.headers()) as ws:
            shown = await server.call("notch_show", {"title": "Uploading", "progress": 0.25, "key": "up"})
            check("a card goes up without waiting", not shown["isError"], shown)
            cards = (await first(ws, lambda c: c))["list"]
            check("with its progress", cards[0]["progress"] == 0.25 and cards[0]["kind"] == "show", cards)
            first_id = cards[0]["id"]

            await server.call("notch_show", {"title": "Uploading", "progress": 0.9, "key": "up"})
            cards = (await first(ws, lambda c: c and c[0]["progress"] == 0.9))["list"]
            check("the same key updates it in place", len(cards) == 1 and cards[0]["id"] == first_id, cards)

            await server.call("notch_show", {"title": "Blink", "seconds": 0.5})
            await first(ws, lambda c: len(c) == 2)
            await first(ws, lambda c: len(c) == 1)
            check("a card goes away when its time is up", True)
            await ws.send(json.dumps({"type": "card_dismiss", "id": first_id}))
            await first(ws, lambda c: not c)
            check("closing one takes it down", True)

            bad = await server.call("notch_ask", {"title": "x", "fields": [{"name": "a", "label": "a", "type": "html"}]})
            check("only the fixed field types are accepted", bad["isError"] and "type" in bad["content"][0]["text"], bad)
            bad = await server.call("notch_ask", {"title": "x", "fields": [
                {"name": "a", "label": "a", "type": "text"}, {"name": "a", "label": "b", "type": "text"}]})
            check("two fields can't share a name", bad["isError"], bad)

            fields = [{"name": "mode", "label": "Mode", "type": "choice", "options": ["A", "B"]},
                      {"name": "size", "label": "Size", "type": "number", "min": 0, "max": 10}]
            call = server.send("tools/call", {"name": "notch_ask", "arguments": {"title": "How?", "fields": fields}})
            card = (await first(ws, lambda c: c))["list"][0]
            check("a form reaches the notch", card["kind"] == "ask" and card["fields"][0]["options"] == ["A", "B"], card)

            await ws.send(json.dumps({"type": "card_answer", "id": card["id"], "answers": {"mode": "C", "size": 3}}))
            try:
                await asyncio.wait_for(server.proc.stdout.readline(), timeout=0.4)
                check("an answer that isn't an option is refused", False)
            except asyncio.TimeoutError:
                check("an answer that isn't an option is refused", True)

            await ws.send(json.dumps({"type": "card_answer", "id": card["id"], "answers": {"mode": "B", "size": 3}}))
            reply = await server.reply()
            check("the answers go back to the session", reply["id"] == call and json.loads(
                reply["result"]["content"][0]["text"]) == {"answered": True, "answers": {"mode": "B", "size": 3}}, reply)
            await first(ws, lambda c: not c)

            server.send("tools/call", {"name": "notch_ask", "arguments": {"title": "Again?", "fields": fields}})
            card = (await first(ws, lambda c: c))["list"][0]
            await ws.send(json.dumps({"type": "card_dismiss", "id": card["id"]}))
            text = (await server.reply())["result"]["content"][0]["text"]
            check("dismissing tells the session", json.loads(text) == {"answered": False, "reason": "the user dismissed it"}, text)
            await first(ws, lambda c: not c)

            server.send("tools/call", {"name": "notch_ask", "arguments": {"title": "Slow?", "fields": fields, "wait_seconds": 0.5}})
            await first(ws, lambda c: c)
            text = (await server.reply())["result"]["content"][0]["text"]
            check("nobody answering says so", json.loads(text)["answered"] is False, text)
            await first(ws, lambda c: not c)

            stale = server.send("tools/call", {"name": "notch_ask", "arguments": {"title": "Cancel?", "fields": fields}})
            await first(ws, lambda c: c)
            server.cancel(stale)
            await first(ws, lambda c: not c)
            check("a cancelled call takes its form down", True)
            await server.reply()

        no_daemon = Server({**env, "NOTCH_INBOX_PORT": "18799"})
        await no_daemon.start()
        down = await no_daemon.call("notch_show", {"title": "x"})
        check("no notch is an error the session can read", down["isError"], down)
        no_daemon.proc.kill()

        no_token = Server({**env, "NOTCH_TOKEN_FILE": str(home / "absent")})
        await no_token.start()
        refused = await no_token.call("notch_show", {"title": "x"})
        check("no token puts up no card", refused["isError"], refused)
        no_token.proc.kill()
    finally:
        server.proc.kill()
        daemon.terminate()
        await daemon.wait()

    print("all good" if not failures else f"{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
