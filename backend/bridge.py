import asyncio
import json
from typing import Any, Awaitable, Callable

import websockets
from loguru import logger

Handler = Callable[[dict[str, Any]], Awaitable[None]]


class NotchBridge:
    """Local WebSocket fan-out to the SwiftUI notch shell.

    Backend -> shell:  state | transcript | assistant_delta | assistant_done |
                       tool | error | session
    Shell -> backend:  interrupt | text | ptt | approve | say
    """

    def __init__(self, host: str, port: int):
        self.host = host
        self.port = port
        self._clients: set[Any] = set()
        self._server = None
        self._handlers: dict[str, Handler] = {}
        self._last_state = "idle"
        # What a client is told the moment it connects. The voice backend replays
        # its state; the agents daemon replays its last roster instead, and must
        # not send a state frame at all — the notch's phase belongs to the voice.
        self._hello: Callable[[], dict[str, Any] | None] | None = None

    @property
    def last_state(self) -> str:
        return self._last_state

    def on(self, msg_type: str, handler: Handler):
        self._handlers[msg_type] = handler

    def on_connect(self, hello: Callable[[], dict[str, Any] | None]):
        self._hello = hello

    async def start(self):
        self._server = await websockets.serve(self._client_loop, self.host, self.port)
        logger.info(f"notch bridge listening on ws://{self.host}:{self.port}")

    async def stop(self):
        if self._server:
            self._server.close()
            await self._server.wait_closed()

    async def _client_loop(self, ws):
        self._clients.add(ws)
        logger.info(f"shell connected ({len(self._clients)} client(s))")
        try:
            hello = self._hello() if self._hello else {"type": "state", "value": self._last_state}
            if hello:
                await ws.send(json.dumps(hello))
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                handler = self._handlers.get(msg.get("type", ""))
                if handler:
                    await handler(msg)
                else:
                    logger.debug(f"unhandled shell message: {msg}")
        except websockets.ConnectionClosed:
            pass
        finally:
            self._clients.discard(ws)
            logger.info("shell disconnected")

    async def send(self, payload: dict[str, Any]):
        if payload.get("type") == "state":
            self._last_state = payload.get("value", self._last_state)
        if not self._clients:
            return
        raw = json.dumps(payload)
        await asyncio.gather(
            *(self._safe_send(ws, raw) for ws in list(self._clients)), return_exceptions=True
        )

    @staticmethod
    async def _safe_send(ws, raw: str):
        try:
            await ws.send(raw)
        except Exception:
            pass

    async def state(self, value: str):
        await self.send({"type": "state", "value": value})
