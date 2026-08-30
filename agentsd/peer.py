"""Talking to a session the notch didn't start.

Every Claude Code session serves a Unix socket and accepts newline-delimited
JSON: an `auth` frame carrying the peer token from its own key file, then a
`user` frame that lands in its input queue. This is the same path Claude's own
SendMessage tool takes.

None of it is documented. Every wire constant lives in this module so a version
bump breaks one file, and a failure here only ever costs you the ability to talk
to foreign agents — the roster keeps working.
"""
import asyncio
import json
import time
from dataclasses import dataclass

from loguru import logger

from agentsd import paths

AUTH_FRAME = "auth"
USER_FRAME = "user"
PROTOCOL = 1

# A busy session holds an inbound message and shows its user a dialog rather
# than injecting it mid-turn, so we sit on it until it goes idle. Only a state we
# positively know is mid-turn holds a message: a headless `claude -p` session
# registers without a status at all, and refusing to talk to it would be worse
# than letting the far end decide.
HOLD_WHEN = {"working"}

# How long a held message waits for a busy session before it is given up on.
# A foreign agent can't be steered — it has no input channel we can cut into —
# so the only alternative to a deadline is holding words forever.
HOLD_TTL_S = 120.0


@dataclass
class Receipt:
    session_id: str
    status: str  # queued | delivered | refused
    detail: str = ""

    def as_dict(self) -> dict:
        return {"type": "delivery", "id": self.session_id, "status": self.status,
                "detail": self.detail}


def _token(pid: int) -> str:
    path = paths.key_file(pid)
    if not path:
        return ""
    try:
        return json.loads(path.read_text()).get("peerToken") or ""
    except (OSError, json.JSONDecodeError):
        return ""


async def deliver(socket_path: str, pid: int, session_id: str, text: str) -> Receipt:
    token = _token(pid)
    if not token:
        return Receipt(session_id, "refused", "no peer token")

    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_unix_connection(socket_path), timeout=5
        )
    except (OSError, asyncio.TimeoutError) as e:
        return Receipt(session_id, "refused", f"socket: {e}")

    try:
        for frame in (
            {"type": AUTH_FRAME, "token": token},
            # session_id is checked by the far end: if this pid now belongs to a
            # different session, the message is dropped instead of misdelivered.
            {
                "type": USER_FRAME,
                "session_id": session_id,
                "message": {"role": "user", "content": text},
            },
        ):
            writer.write((json.dumps(frame) + "\n").encode())
        await writer.drain()
        # Receipts come back on the same connection; not waiting long for one.
        try:
            line = await asyncio.wait_for(reader.readline(), timeout=1.5)
        except asyncio.TimeoutError:
            line = b""
    finally:
        writer.close()

    if line:
        try:
            reply = json.loads(line)
            if reply.get("status") in ("denied", "refused"):
                return Receipt(session_id, "refused", str(reply.get("reason", "")))
        except json.JSONDecodeError:
            pass
    return Receipt(session_id, "delivered")


class Messenger:
    """Holds messages for busy agents and delivers them the moment they're free."""

    def __init__(self, hold_ttl_s: float = HOLD_TTL_S):
        # session id -> [(text, held since)]
        self._held: dict[str, list[tuple[str, float]]] = {}
        self._ttl = hold_ttl_s

    def pending(self, session_id: str) -> int:
        return len(self._held.get(session_id, []))

    async def send(self, session, text: str) -> Receipt:
        """`session` is an agentsd.registry.LiveSession."""
        if not session.reachable:
            return Receipt(session.session_id, "refused", "no messaging socket")
        if session.state in HOLD_WHEN:
            self._held.setdefault(session.session_id, []).append((text, time.monotonic()))
            logger.info(f"holding a message for {session.name or session.session_id} until it's idle")
            return Receipt(session.session_id, "queued", "busy")
        return await deliver(session.socket_path, session.pid, session.session_id, text)

    async def pump(self, sessions) -> list[Receipt]:
        """Called each tick with the live roster; flushes what can now land."""
        receipts = []
        by_id = {s.session_id: s for s in sessions}
        now = time.monotonic()
        for session_id, items in list(self._held.items()):
            session = by_id.get(session_id)
            if not session:
                del self._held[session_id]
                receipts.append(Receipt(session_id, "refused", "session ended"))
                continue
            if session.state in HOLD_WHEN:
                stale = [t for t, since in items if now - since >= self._ttl]
                fresh = [(t, since) for t, since in items if now - since < self._ttl]
                if stale:
                    self._held[session_id] = fresh
                    if not fresh:
                        del self._held[session_id]
                    receipts.append(
                        Receipt(session_id, "refused", f"still busy after {int(self._ttl)}s")
                    )
                continue
            del self._held[session_id]
            for text, _ in items:
                receipts.append(
                    await deliver(session.socket_path, session.pid, session_id, text)
                )
        return receipts
