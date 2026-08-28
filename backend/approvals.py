import asyncio
import json
import uuid
from typing import Any, Awaitable, Callable

from loguru import logger

Asker = Callable[[dict[str, Any]], Awaitable[None]]


class ApprovalServer:
    """Answers permission questions asked by the PreToolUse hook.

    Claude Code's stdio transport won't delegate `can_use_tool` to a hand-rolled
    client, so the ask comes the other way round: a PreToolUse hook subprocess
    connects here, describes the tool call, and blocks on one line of JSON back.
    Meanwhile the agent asks the user out loud and the notch shows Approve/Deny.
    """

    def __init__(self, host: str, port: int, timeout_s: float = 120.0):
        self.host = host
        self.port = port
        self.timeout_s = timeout_s
        self._server: asyncio.Server | None = None
        self._pending: dict[str, asyncio.Future[tuple[bool, str]]] = {}
        self._ask: Asker | None = None

    def on_ask(self, ask: Asker):
        self._ask = ask

    @property
    def pending_id(self) -> str | None:
        """The request currently waiting on the user, if any."""
        for req_id, fut in self._pending.items():
            if not fut.done():
                return req_id
        return None

    async def start(self):
        self._server = await asyncio.start_server(self._handle, self.host, self.port)
        logger.info(f"approval server listening on {self.host}:{self.port}")

    async def stop(self):
        for fut in self._pending.values():
            if not fut.done():
                fut.set_result((False, "shutting down"))
        if self._server:
            self._server.close()
            await self._server.wait_closed()

    def resolve(self, req_id: str, approved: bool, reason: str = "") -> bool:
        fut = self._pending.get(req_id)
        if not fut or fut.done():
            return False
        fut.set_result((approved, reason))
        return True

    def resolve_pending(self, approved: bool, reason: str = "") -> bool:
        req_id = self.pending_id
        return self.resolve(req_id, approved, reason) if req_id else False

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        req_id = uuid.uuid4().hex[:12]
        try:
            raw = await asyncio.wait_for(reader.readline(), timeout=5)
            payload = json.loads(raw or b"{}")
        except (asyncio.TimeoutError, json.JSONDecodeError) as e:
            logger.warning(f"bad approval request: {e}")
            writer.close()
            return

        fut: asyncio.Future[tuple[bool, str]] = asyncio.get_running_loop().create_future()
        self._pending[req_id] = fut
        try:
            if self._ask:
                await self._ask({**payload, "id": req_id})
            approved, reason = await asyncio.wait_for(fut, timeout=self.timeout_s)
        except asyncio.TimeoutError:
            approved, reason = False, "no answer in time"
        except Exception as e:
            approved, reason = False, str(e)
        finally:
            self._pending.pop(req_id, None)

        writer.write((json.dumps({"approved": approved, "reason": reason}) + "\n").encode())
        try:
            await writer.drain()
        except Exception:
            pass
        writer.close()
