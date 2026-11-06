"""The voice backend's view of the agents daemon: roster, open questions, events.

The daemon owns approvals; this mirrors them so a spoken "yes" can answer one,
and passes along what's worth saying out loud.
"""
import asyncio
import json
from typing import Any, Awaitable, Callable

import websockets
from loguru import logger

from backend import auth

Listener = Callable[[dict[str, Any]], Awaitable[None]]


class Fleet:
    def __init__(self, url: str):
        self.url = url
        self.agents: list[dict] = []
        self.approvals: list[dict] = []
        self.totals: dict = {}
        self.connected = False
        self._ws = None
        self._task: asyncio.Task | None = None
        self._seen: set[str] = set()
        # session id -> waiter for the daemon's word on a line typed into it.
        self._typing: dict[str, asyncio.Future] = {}
        self.on_new_approval: Listener | None = None
        self.on_event: Listener | None = None

    async def start(self):
        self._task = asyncio.create_task(self._run())

    async def stop(self):
        if self._task:
            self._task.cancel()

    async def answer(self, req_id: str, approved: bool, always: bool = False, how: str = "by voice") -> bool:
        if not self._ws:
            return False
        try:
            await self._ws.send(
                json.dumps({"type": "approve", "id": req_id, "approved": approved, "always": always, "how": how})
            )
        except websockets.ConnectionClosed:
            return False
        self.approvals = [a for a in self.approvals if a["id"] != req_id]
        return True

    async def _send(self, msg: dict) -> bool:
        if not self._ws:
            return False
        try:
            await self._ws.send(json.dumps(msg))
        except websockets.ConnectionClosed:
            return False
        return True

    def hosted(self, session_id: str) -> bool:
        """Runs in the daemon's own pty, so it can be typed into and interrupted."""
        return any(a["id"] == session_id and a.get("host") == "window" for a in self.agents)

    async def type(self, session_id: str, text: str, steer: bool = True) -> str:
        """sent | steered | waiting | gone — or unknown if the daemon never said."""
        waiter = asyncio.get_running_loop().create_future()
        self._typing[session_id] = waiter
        try:
            if not await self._send({"type": "type", "id": session_id, "text": text, "steer": steer}):
                return "gone"
            return await asyncio.wait_for(waiter, timeout=5)
        except asyncio.TimeoutError:
            return "unknown"
        finally:
            self._typing.pop(session_id, None)

    async def interrupt(self, session_id: str) -> bool:
        return await self._send({"type": "interrupt", "id": session_id})

    def approval(self, req_id: str) -> dict | None:
        return next((a for a in self.approvals if a["id"] == req_id), None)

    async def _run(self):
        delay = 0.5
        while True:
            try:
                async with websockets.connect(self.url, additional_headers=auth.headers()) as ws:
                    self._ws, self.connected, delay = ws, True, 0.5
                    logger.info(f"fleet: connected to {self.url}")
                    async for raw in ws:
                        await self._apply(json.loads(raw))
            except (OSError, websockets.WebSocketException, json.JSONDecodeError) as e:
                if self.connected:
                    logger.warning(f"fleet: lost the agents daemon ({e})")
            finally:
                self._ws, self.connected = None, False
                self.agents, self.approvals, self.totals = [], [], {}
            await asyncio.sleep(delay)
            delay = min(delay * 2, 5.0)

    async def _apply(self, msg: dict):
        kind = msg.get("type")
        if kind == "agents":
            self.agents = msg.get("list") or []
            self.totals = msg.get("fleet") or {}
        elif kind == "approvals":
            self.approvals = msg.get("list") or []
            # Ids are never reused, so remembering only the open ones is enough —
            # and it survives a reconnect without announcing everything again.
            fresh = [a for a in self.approvals if a["id"] not in self._seen]
            self._seen = {a["id"] for a in self.approvals}
            if self.on_new_approval:
                for request in fresh:
                    await self.on_new_approval(request)
        elif kind == "typed":
            waiter = self._typing.get(msg.get("id", ""))
            if waiter and not waiter.done():
                waiter.set_result(msg.get("status") or "unknown")
        elif kind == "fleet_event" and self.on_event:
            await self.on_event(msg)
