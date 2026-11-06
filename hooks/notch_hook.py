#!/usr/bin/env python3
"""The notch's one hook, for every Claude Code session on the machine.

Stdlib only — `scripts/install-hooks.sh` copies it to ~/.claude/hooks and runs
it under /usr/bin/python3, so it keeps working when the repo moves.

- PermissionRequest (interactive sessions, installed globally): Claude Code's
  own dialog is already on screen; this puts the same question in the notch and
  waits. An answer from the notch closes the dialog. No notch, or the dialog
  answered in the terminal, and this exits with nothing to say.
- PreToolUse (only the `claude -p` agents the notch starts, via --settings):
  there's no dialog behind it, so a question nobody can see is a no.
- Stop: tells the notch a turn ended, and exits without waiting.
"""
from __future__ import annotations

import json
import os
import re
import socket
import sys

HOST = os.getenv("NOTCH_INBOX_HOST", "127.0.0.1")
PORT = int(os.getenv("NOTCH_INBOX_PORT", "8766"))
OWNED_WAIT_S = float(os.getenv("APPROVAL_TIMEOUT_S", "180"))
TERMINAL_WAIT_S = float(os.getenv("NOTCH_TERMINAL_WAIT_S", "590"))
# Where backend/auth.py keeps it. The inbox drops a line that doesn't show it.
TOKEN_FILE = os.getenv("NOTCH_TOKEN_FILE") or os.path.expanduser(
    "~/Library/Application Support/notch-agent/bridge-token"
)


def token() -> str:
    try:
        with open(TOKEN_FILE) as f:
            return f.read().strip()
    except OSError:
        return ""

# Keep in step with agentsd/risk.py.
RISKY_BASH = re.compile(
    r"""(?x)
    \brm\s+(-\w*\s+)*-\w*[rf] |
    \bsudo\b | \bchmod\s+777\b | \bmkfs\b | \bdd\s+if= |
    \bgit\s+(push|reset\s+--hard|clean\s+-\w*f|checkout\s+--\s|branch\s+-D) |
    \bnpm\s+publish\b | \bpip\s+install\b | \bbrew\s+(install|uninstall)\b |
    \bcurl\b.*\|\s*(ba)?sh | \bkillall\b | \bshutdown\b | \blaunchctl\b |
    >\s*/(etc|usr|bin|sbin|System|Library)/
    """
)


def needs_asking(tool: str, args: dict, cwd: str) -> bool:
    """For notch-started agents, which run in auto mode: only the risky minority."""
    if tool == "Bash":
        return bool(RISKY_BASH.search(args.get("command", "")))
    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        path = args.get("file_path") or args.get("notebook_path") or ""
        if not path:
            return False
        root = os.path.abspath(cwd)
        return os.path.commonpath([os.path.abspath(path), root]) != root
    return tool == "WebFetch"


def ask(request: dict, wait_s: float) -> dict | None:
    """One line out, one line back. None when the inbox isn't there or hung up."""
    try:
        sock = socket.create_connection((HOST, PORT), timeout=1)
    except OSError:
        return None
    with sock:
        sock.sendall((json.dumps({**request, "token": token()}) + "\n").encode())
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
    try:
        return json.loads(buf) if buf.strip() else None
    except json.JSONDecodeError:
        return None


def tell(event: dict):
    try:
        with socket.create_connection((HOST, PORT), timeout=0.5) as sock:
            sock.sendall((json.dumps({"kind": "event", "token": token(), **event}) + "\n").encode())
    except OSError:
        pass


def request_from(event: dict, source: str) -> dict:
    return {
        "kind": "permission",
        "source": source,
        "session_id": event.get("session_id", ""),
        "cwd": event.get("cwd") or os.getcwd(),
        # The hook's parent is the claude process — that's what the registry keys on.
        "pid": os.getppid(),
        "tool": event.get("tool_name", ""),
        "input": event.get("tool_input") or {},
        "suggestions": event.get("permission_suggestions") or [],
    }


def permission_request(event: dict):
    answer = ask(request_from(event, "terminal"), TERMINAL_WAIT_S)
    if not answer or answer.get("decision") not in ("allow", "deny"):
        return
    decision = {"behavior": answer["decision"]}
    if answer["decision"] == "allow" and answer.get("permissions"):
        decision["updatedPermissions"] = answer["permissions"]
    if answer["decision"] == "allow" and answer.get("updatedInput"):
        decision["updatedInput"] = answer["updatedInput"]
    if answer["decision"] == "deny":
        decision["message"] = answer.get("reason") or "denied from the notch"
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}))


def pre_tool_use(event: dict):
    tool = event.get("tool_name", "")
    args = event.get("tool_input") or {}
    if not needs_asking(tool, args, event.get("cwd") or os.getcwd()):
        return
    answer = ask(request_from(event, "owned"), OWNED_WAIT_S + 5)
    if answer is None:
        decision, reason = "deny", "the notch inbox isn't running, so nobody could approve this"
    elif answer.get("decision") == "allow":
        decision, reason = "allow", answer.get("reason") or "approved from the notch"
    else:
        decision, reason = "deny", answer.get("reason") or "declined from the notch"
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": decision,
                    "permissionDecisionReason": reason,
                }
            }
        )
    )


def main():
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return
    name = event.get("hook_event_name")
    if name == "PermissionRequest":
        permission_request(event)
    elif name == "PreToolUse":
        pre_tool_use(event)
    elif name == "Stop":
        tell({"event": "stop", "session_id": event.get("session_id", ""),
              "cwd": event.get("cwd", ""), "pid": os.getppid()})


if __name__ == "__main__":
    main()
