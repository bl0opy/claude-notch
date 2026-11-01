"""Cards a Claude session puts in the notch through hooks/notch_mcp.py.

A session fills in a fixed shape, checked here, and the notch draws it. Answers
are checked against the fields before going back, so what a session gets is what
it asked for. Nothing here touches permissions: a card's answer goes to the
session that asked and nowhere else.
"""
import asyncio
import json
import time
import uuid
from dataclasses import dataclass, field

from loguru import logger

from agentsd.registry import from_registry
from agentsd.snapshot import project_name

MAX_FIELDS = 8
MAX_OPTIONS = 12
SHORT = 200
LONG = 6_000
DEFAULT_SHOW_S = 60
MAX_WAIT_S = 3_600
FIELD_TYPES = {"choice", "multichoice", "text", "number", "toggle"}


def _text(value, limit: int) -> str:
    return str(value or "").strip()[:limit]


def clean_field(raw: dict) -> dict:
    kind, name = raw.get("type"), _text(raw.get("name"), SHORT)
    if kind not in FIELD_TYPES:
        raise ValueError(f"a field's type has to be one of {sorted(FIELD_TYPES)}")
    if not name:
        raise ValueError("every field needs a name")
    out = {"name": name, "label": _text(raw.get("label"), SHORT) or name, "type": kind}
    if kind in ("choice", "multichoice"):
        options = [_text(o, SHORT) for o in raw.get("options") or [] if _text(o, SHORT)]
        if not options:
            raise ValueError(f"{name} needs options")
        if len(options) > MAX_OPTIONS:
            raise ValueError(f"{name} has more than {MAX_OPTIONS} options")
        out["options"] = options
    elif kind == "number":
        try:
            low, high = float(raw.get("min", 0)), float(raw.get("max", 100))
            step = float(raw.get("step") or (high - low) / 100 or 1)
        except (TypeError, ValueError):
            raise ValueError(f"{name}'s min, max and step have to be numbers") from None
        if low >= high or step <= 0:
            raise ValueError(f"{name} needs min below max and a positive step")
        out.update(min=low, max=high, step=step)
    elif kind == "text":
        out["placeholder"] = _text(raw.get("placeholder"), SHORT)
    default = raw.get("default")
    try:
        if default is not None:
            out["default"] = clean_value(out, default)
    except ValueError:
        pass
    return out


def clean_value(spec: dict, value):
    """An answer for one field, or ValueError if it isn't one that field allows."""
    kind = spec["type"]
    if kind == "choice":
        if value not in spec["options"]:
            raise ValueError(f"{spec['name']}: not one of its options")
        return value
    if kind == "multichoice":
        if not isinstance(value, list) or any(v not in spec["options"] for v in value):
            raise ValueError(f"{spec['name']}: not a list of its options")
        return value
    if kind == "text":
        return str(value)[:LONG]
    if kind == "number":
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not spec["min"] <= value <= spec["max"]:
            raise ValueError(f"{spec['name']}: not a number in range")
        return value
    if not isinstance(value, bool):
        raise ValueError(f"{spec['name']}: not true or false")
    return value


def clean_answers(fields: list[dict], answers: dict) -> dict:
    return {f["name"]: clean_value(f, answers[f["name"]]) for f in fields if f["name"] in answers}


@dataclass
class Card:
    kind: str
    project: str
    session_id: str
    title: str
    body: str = ""
    fields: list = field(default_factory=list)
    progress: float | None = None
    key: str = ""
    id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])
    created: float = field(default_factory=time.time)
    expires: float | None = None
    future: asyncio.Future | None = None

    def as_dict(self) -> dict:
        return {
            "id": self.id,
            "kind": self.kind,
            "project": self.project,
            "sessionId": self.session_id,
            "title": self.title,
            "body": self.body,
            "fields": self.fields,
            "progress": self.progress,
        }


class Cards:
    def __init__(self, broadcast):
        self._broadcast = broadcast
        self._cards: dict[str, Card] = {}

    def snapshot(self) -> dict:
        rows = sorted(self._cards.values(), key=lambda c: c.created)
        return {"type": "cards", "list": [c.as_dict() for c in rows]}

    async def _changed(self):
        await self._broadcast(self.snapshot())

    def _build(self, msg: dict) -> Card:
        raw = msg.get("card") or {}
        title = _text(raw.get("title"), SHORT)
        if not title:
            raise ValueError("a card needs a title")
        pid = int(msg.get("pid") or 0)
        row = from_registry().get(pid) or {}
        cwd = row.get("cwd") or msg.get("cwd") or ""
        card = Card(
            kind=msg["kind"],
            project=project_name(cwd) if cwd else "",
            session_id=row.get("sessionId") or "",
            title=title,
            body=_text(raw.get("body"), LONG),
            key=_text(raw.get("key"), SHORT),
        )
        if card.kind == "ask":
            fields = raw.get("fields") or []
            if not fields or len(fields) > MAX_FIELDS:
                raise ValueError(f"a form takes 1 to {MAX_FIELDS} fields")
            card.fields = [clean_field(f) for f in fields if isinstance(f, dict)]
            if len({f["name"] for f in card.fields}) != len(fields):
                raise ValueError("every field needs its own name")
        else:
            progress = raw.get("progress")
            if isinstance(progress, (int, float)) and not isinstance(progress, bool):
                card.progress = max(0.0, min(1.0, float(progress)))
            seconds = raw.get("seconds")
            seconds = float(seconds) if isinstance(seconds, (int, float)) and seconds > 0 else DEFAULT_SHOW_S
            card.expires = time.time() + min(seconds, MAX_WAIT_S)
        return card

    async def handle(self, msg: dict, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        try:
            card = await asyncio.to_thread(self._build, msg)
        except (ValueError, TypeError) as e:
            await self._reply(writer, {"error": str(e)})
            return
        if card.kind == "show":
            await self._show(card)
            await self._reply(writer, {"shown": True})
        else:
            await self._ask(card, msg, reader, writer)

    async def _show(self, card: Card):
        if card.key:
            for old in list(self._cards.values()):
                if old.key == card.key and old.session_id == card.session_id and old.kind == "show":
                    card.id, card.created = old.id, old.created
        self._cards[card.id] = card
        await self._changed()

    async def _ask(self, card: Card, msg: dict, reader, writer):
        card.future = asyncio.get_running_loop().create_future()
        self._cards[card.id] = card
        await self._changed()
        raw_wait = (msg.get("card") or {}).get("wait_seconds")
        wait_s = min(float(raw_wait), MAX_WAIT_S) if isinstance(raw_wait, (int, float)) and raw_wait > 0 else 300
        closed = asyncio.create_task(reader.read())
        try:
            await asyncio.wait({card.future, closed}, timeout=wait_s, return_when=asyncio.FIRST_COMPLETED)
            if card.future.done():
                answer = card.future.result()
            elif closed.done():
                answer = None
            else:
                answer = {"answered": False, "reason": "no answer in time"}
        finally:
            closed.cancel()
            self._cards.pop(card.id, None)
            await self._changed()
        if answer is not None:
            await self._reply(writer, answer)
        else:
            writer.close()

    @staticmethod
    async def _reply(writer: asyncio.StreamWriter, reply: dict):
        writer.write((json.dumps(reply) + "\n").encode())
        try:
            await writer.drain()
        except ConnectionError:
            pass
        writer.close()

    def answer(self, card_id: str, answers: dict) -> bool:
        card = self._cards.get(card_id)
        if not card or not card.future or card.future.done():
            return False
        try:
            cleaned = clean_answers(card.fields, answers)
        except ValueError as e:
            logger.warning(f"card answer refused: {e}")
            return False
        card.future.set_result({"answered": True, "answers": cleaned})
        return True

    async def dismiss(self, card_id: str):
        card = self._cards.get(card_id)
        if not card:
            return
        if card.future:
            if not card.future.done():
                card.future.set_result({"answered": False, "reason": "the user dismissed it"})
            return
        del self._cards[card_id]
        await self._changed()

    async def expire(self, now: float | None = None):
        now = time.time() if now is None else now
        gone = [c.id for c in self._cards.values() if c.expires is not None and c.expires <= now]
        for card_id in gone:
            del self._cards[card_id]
        if gone:
            await self._changed()
