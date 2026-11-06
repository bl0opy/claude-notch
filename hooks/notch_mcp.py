#!/usr/bin/env python3
"""Lets any Claude session put a card in the notch: an MCP server over stdio.

- notch_ask: a small form, and the session waits for your answers.
- notch_show: something to look at, updated in place, nobody waits.

Sessions fill in a fixed set of card types and can't send interface code, so one
that has read a malicious page can't draw something that passes for the notch's
own permission card. An answer only ever goes back to the session that asked, so
it can't approve anything.

Stdlib only, like the hook: `scripts/install-mcp.sh` copies it to ~/.claude/hooks
and runs it under /usr/bin/python3, so it keeps working when the repo moves.
"""
from __future__ import annotations

import json
import os
import socket
import sys
import threading

HOST = os.getenv("NOTCH_INBOX_HOST", "127.0.0.1")
PORT = int(os.getenv("NOTCH_INBOX_PORT", "8766"))
TOKEN_FILE = os.getenv("NOTCH_TOKEN_FILE") or os.path.expanduser(
    "~/Library/Application Support/notch-agent/bridge-token"
)
DEFAULT_ASK_WAIT_S = 300
PROTOCOL_VERSION = "2025-06-18"

FIELD = {
    "type": "object",
    "properties": {
        "name": {"type": "string", "description": "Key this field's answer comes back under."},
        "label": {"type": "string"},
        "type": {"type": "string", "enum": ["choice", "multichoice", "text", "number", "toggle"]},
        "options": {"type": "array", "items": {"type": "string"}, "description": "For choice and multichoice."},
        "min": {"type": "number", "description": "For number."},
        "max": {"type": "number", "description": "For number."},
        "step": {"type": "number", "description": "For number."},
        "default": {"description": "What it starts as."},
        "placeholder": {"type": "string", "description": "For text."},
    },
    "required": ["name", "label", "type"],
}

TOOLS = [
    {
        "name": "notch_ask",
        "description": (
            "Ask the user something in the MacBook notch with a small form, and wait for the answers. "
            "Use it when a typed question would be slower than a slider, a toggle or a few choices. "
            "It can't approve anything: an answer is just data for you."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "The question, in a line."},
                "body": {"type": "string", "description": "Optional markdown with more detail."},
                "fields": {"type": "array", "items": FIELD, "minItems": 1},
                "wait_seconds": {"type": "number", "description": f"How long to wait. Default {DEFAULT_ASK_WAIT_S}."},
            },
            "required": ["title", "fields"],
        },
    },
    {
        "name": "notch_show",
        "description": (
            "Show the user a card in the MacBook notch, without waiting: progress on something long, "
            "a table, or a diff. Body is markdown, including tables and ```diff fences. "
            "Calling again with the same key updates that card in place."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "body": {"type": "string", "description": "Markdown."},
                "progress": {"type": "number", "description": "0 to 1, for a progress bar."},
                "key": {"type": "string", "description": "Reuse to update the same card."},
                "seconds": {"type": "number", "description": "How long it stays up. Default 60."},
            },
            "required": ["title"],
        },
    },
]

_write = threading.Lock()
_open: dict = {}


def send(message: dict):
    with _write:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()


def token() -> str:
    try:
        with open(TOKEN_FILE) as f:
            return f.read().strip()
    except OSError:
        return ""


def to_notch(kind: str, args: dict, wait_s: float, call_id=None) -> dict | None:
    """One line out, one line back. None when the daemon isn't there or hung up."""
    request = {
        "kind": kind,
        "token": token(),
        # The session is this process's parent, which is what the registry keys on.
        "pid": os.getppid(),
        "cwd": os.getcwd(),
        "card": args,
    }
    try:
        sock = socket.create_connection((HOST, PORT), timeout=2)
    except OSError:
        return None
    _open[call_id] = sock
    try:
        with sock:
            sock.sendall((json.dumps(request) + "\n").encode())
            sock.settimeout(wait_s)
            buf = b""
            try:
                while not buf.endswith(b"\n"):
                    chunk = sock.recv(65536)
                    if not chunk:
                        break
                    buf += chunk
            except OSError:
                return None
    finally:
        _open.pop(call_id, None)
    try:
        return json.loads(buf) if buf.strip() else None
    except json.JSONDecodeError:
        return None


def result(call_id, text: str, error: bool = False):
    send({"jsonrpc": "2.0", "id": call_id, "result": {
        "content": [{"type": "text", "text": text}], "isError": error,
    }})


def call_tool(call_id, name: str, args: dict):
    if name == "notch_ask":
        wait_s = float(args.get("wait_seconds") or DEFAULT_ASK_WAIT_S)
        reply = to_notch("ask", {**args, "wait_seconds": wait_s}, wait_s + 5, call_id)
    elif name == "notch_show":
        reply = to_notch("show", args, 5, call_id)
    else:
        result(call_id, f"no tool called {name}", error=True)
        return
    if reply is None:
        result(call_id, "The notch isn't running, or isn't answering, so the user didn't see this.", error=True)
    elif reply.get("error"):
        result(call_id, reply["error"], error=True)
    else:
        result(call_id, json.dumps(reply))


def handle(message: dict):
    method, call_id = message.get("method"), message.get("id")
    if method == "initialize":
        requested = (message.get("params") or {}).get("protocolVersion") or PROTOCOL_VERSION
        send({"jsonrpc": "2.0", "id": call_id, "result": {
            "protocolVersion": requested,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "notch", "version": "1.0.0"},
        }})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": call_id, "result": {"tools": TOOLS}})
    elif method == "tools/call":
        params = message.get("params") or {}
        # On its own thread: notch_ask waits on a person, and pings still get answered.
        threading.Thread(
            target=call_tool, args=(call_id, params.get("name"), params.get("arguments") or {}), daemon=True
        ).start()
    elif method == "ping":
        send({"jsonrpc": "2.0", "id": call_id, "result": {}})
    elif method == "notifications/cancelled":
        # Hanging up takes the card down.
        sock = _open.get((message.get("params") or {}).get("requestId"))
        if sock:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
    elif call_id is not None:
        send({"jsonrpc": "2.0", "id": call_id, "error": {"code": -32601, "message": f"no method {method}"}})


def main():
    for line in sys.stdin:
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        handle(message)


if __name__ == "__main__":
    main()
