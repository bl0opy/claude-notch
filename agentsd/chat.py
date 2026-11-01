"""A session's conversation so far, read back from its transcript.

The notch shows it the way the app does, minus the noise: what you said, what
Claude said, and one line per tool call. Tool results, reminders and the
transcript's bookkeeping rows are left out.

Only the tail of the file is read — a long session's transcript runs to tens
of megabytes, and the panel shows the last few dozen rows.
"""
import json
from pathlib import Path

from agentsd import paths, risk

TAIL_BYTES = 1_500_000
ROWS = 60
TEXT_CHARS = 1_200
# How a message from another session (the notch's own replies included) opens.
PEER_OPENER = "Another Claude session sent a message:\n"


def _tail(path: Path, size: int = TAIL_BYTES) -> list[dict]:
    try:
        with path.open("rb") as f:
            f.seek(0, 2)
            end = f.tell()
            f.seek(max(0, end - size))
            data = f.read()
    except OSError:
        return []
    lines = data.split(b"\n")
    if end > size:
        lines = lines[1:]  # the first one was cut in half
    rows = []
    for line in lines:
        try:
            rows.append(json.loads(line))
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
    return rows


def _clip(text: str, limit: int = TEXT_CHARS) -> str:
    text = text.strip()
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def _peer_text(content: str) -> str:
    body = content[len(PEER_OPENER):]
    return body.split("\n\nThis came from another Claude session", 1)[0]


def rows_of(entries: list[dict]) -> list[dict]:
    """Transcript entries in, chat rows out: {role, text}, role being you, claude, tool or notch."""
    out = []
    for entry in entries:
        kind = entry.get("type")
        if entry.get("isSidechain"):
            continue
        content = (entry.get("message") or {}).get("content")
        if kind == "user":
            if isinstance(content, str):
                if entry.get("isMeta"):
                    if content.startswith(PEER_OPENER):
                        out.append({"role": "notch", "text": _clip(_peer_text(content))})
                    continue
                out.append({"role": "you", "text": _clip(content)})
            elif isinstance(content, list) and not entry.get("isMeta"):
                text = " ".join(b.get("text", "") for b in content if b.get("type") == "text")
                if text.strip():
                    out.append({"role": "you", "text": _clip(text)})
        elif kind == "assistant" and isinstance(content, list):
            for block in content:
                if block.get("type") == "text" and block.get("text", "").strip():
                    out.append({"role": "claude", "text": _clip(block["text"])})
                elif block.get("type") == "tool_use":
                    name = block.get("name") or "tool"
                    detail = risk.detail(name, block.get("input") or {})
                    out.append({"role": "tool", "text": _clip(f"{name}({detail})" if detail else name, 200)})
    return out


def chat(cwd: str, session_id: str, limit: int = ROWS) -> list[dict]:
    return rows_of(_tail(paths.transcript(cwd, session_id)))[-limit:]


def why(cwd: str, session_id: str) -> str:
    """Why a session is about to call a tool: what it said in this turn before
    calling it, or failing that, what it was asked."""
    rows = rows_of(_tail(paths.transcript(cwd, session_id), 400_000))
    for row in reversed(rows):
        if row["role"] == "claude":
            return row["text"]
        if row["role"] in ("you", "notch"):
            return f"asked: {row['text']}"
    return ""


def last_reply(cwd: str, session_id: str, limit: int = 160) -> str:
    """The first sentence of its last answer, for the line that says it's done."""
    for row in reversed(chat(cwd, session_id, limit=20)):
        if row["role"] == "claude":
            first = row["text"].split("\n", 1)[0]
            for stop in (". ", "! ", "? "):
                if stop in first:
                    first = first.split(stop, 1)[0] + stop.strip()
                    break
            return _clip(first, limit)
        if row["role"] in ("you", "notch"):
            return ""
    return ""
