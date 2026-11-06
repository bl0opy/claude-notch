"""The terminal window: a local page, and a websocket per hosted pty.

    GET  /              the page (window/ in the repo)
    GET  /config.json   where the roster lives, so the page needn't hardcode ports
    WS   /pty/<id>      one hosted session's terminal

Pty frames, server -> page: {"type": "replay"|"out", "data"} | {"type": "exit", "code"}
and page -> server: {"type": "in", "data"} | {"type": "resize", "cols", "rows"}.

A pty socket is a keyboard on a live Claude Code session, so opening one takes
the token in backend/auth.py. A browser may also only open one from this page
itself: any other Origin is refused at the handshake. The page isn't given the
token by this server, which would hand it to anyone who asked: the notch's window
puts it there.
"""
import asyncio
import json
import mimetypes
from pathlib import Path

import websockets
from loguru import logger
from websockets.datastructures import Headers
from websockets.http11 import Response

from agentsd.config import default_agent_path
from agentsd.pty_host import PtyHost
from backend import auth

PAGE_DIR = Path(__file__).resolve().parent.parent / "window"


def page_origins(host: str, port: int) -> list[str | None]:
    return [None, f"http://{host}:{port}", f"http://localhost:{port}"]


def _response(status: int, body: bytes, content_type: str) -> Response:
    headers = Headers(
        [
            ("Content-Type", content_type),
            ("Content-Length", str(len(body))),
            ("Cache-Control", "no-store"),
        ]
    )
    reason = {200: "OK", 404: "Not Found"}.get(status, "")
    return Response(status, reason, headers, body)


class WindowServer:
    def __init__(self, host: str, port: int, pty: PtyHost, roster_url: str):
        self.host = host
        self.port = port
        self.pty = pty
        self.roster_url = roster_url
        self._server = None

    async def start(self):
        self._server = await websockets.serve(
            self._pty_loop,
            self.host,
            self.port,
            process_request=self._http,
            origins=page_origins(self.host, self.port),
            max_size=2**22,
        )
        logger.info(f"terminal window on http://{self.host}:{self.port}")

    async def stop(self):
        if self._server:
            self._server.close()
            await self._server.wait_closed()

    def _http(self, connection, request):
        path = request.path.split("?", 1)[0]
        if path.startswith("/pty/"):
            return auth.refuse_without_token(connection, request)
        if path == "/config.json":
            body = json.dumps({"roster": self.roster_url, "defaultPath": default_agent_path()}).encode()
            return _response(200, body, "application/json")
        return self._static(path)

    def _static(self, path: str) -> Response:
        name = "index.html" if path in ("", "/") else path.lstrip("/")
        target = (PAGE_DIR / name).resolve()
        if PAGE_DIR not in target.parents or not target.is_file():
            return _response(404, b"not found", "text/plain")
        content_type = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        if content_type.startswith("text/") or content_type.endswith("javascript"):
            content_type += "; charset=utf-8"
        return _response(200, target.read_bytes(), content_type)

    async def _pty_loop(self, ws):
        session_id = ws.request.path.split("?", 1)[0].removeprefix("/pty/")
        outbox: asyncio.Queue[dict] = asyncio.Queue()
        hosted = self.pty.attach(session_id, outbox.put_nowait)
        if not hosted:
            await ws.close(4404, "no such session")
            return

        async def pump():
            while True:
                await ws.send(json.dumps(await outbox.get()))

        sender = asyncio.create_task(pump())
        try:
            await ws.send(json.dumps({"type": "replay", "data": hosted.scrollback}))
            if not hosted.running:
                await ws.send(json.dumps({"type": "exit", "code": hosted.exit_code}))
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                kind = msg.get("type")
                if kind == "in":
                    self.pty.write(session_id, str(msg.get("data") or ""))
                elif kind == "resize":
                    self.pty.resize(session_id, int(msg.get("cols") or 0), int(msg.get("rows") or 0))
        except websockets.ConnectionClosed:
            pass
        finally:
            sender.cancel()
            self.pty.detach(session_id, outbox.put_nowait)
