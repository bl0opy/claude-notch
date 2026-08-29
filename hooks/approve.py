#!/usr/bin/env python3
"""PreToolUse hook: asks the voice agent's user before anything risky.

Claude Code runs this before each matched tool call. Safe calls fall straight
through so `auto` mode stays quiet; only the risky minority round-trips to the
backend, which asks the user out loud and shows Approve/Deny in the notch.

Exit 0 with no output = defer to Claude Code's own permission handling.
"""
import json
import os
import re
import socket
import sys

PORT = int(os.getenv("APPROVAL_PORT", "8766"))
HOST = os.getenv("APPROVAL_HOST", "127.0.0.1")
TIMEOUT_S = float(os.getenv("APPROVAL_TIMEOUT_S", "180"))

# Shell that can destroy work, reach the network, or escalate.
RISKY_BASH = re.compile(
    r"""(?x)
    \brm\s+(-\w*\s+)*-\w*[rf] |   # rm -rf and friends
    \bsudo\b | \bchmod\s+777\b | \bmkfs\b | \bdd\s+if= |
    \bgit\s+(push|reset\s+--hard|clean\s+-\w*f|checkout\s+--\s|branch\s+-D) |
    \bnpm\s+publish\b | \bpip\s+install\b | \bbrew\s+(install|uninstall)\b |
    \bcurl\b.*\|\s*(ba)?sh | \bkillall\b | \bshutdown\b | \blaunchctl\b |
    >\s*/(etc|usr|bin|sbin|System|Library)/
    """
)


# What to call each risky call out loud. The notch still shows the real command;
# this is the half-sentence that goes into "I need your approval for ___".
SPOKEN = (
    (re.compile(r"\brm\s+(-\w*\s+)*-\w*[rf]"), "deleting some files"),
    (re.compile(r"\bgit\s+push"), "pushing to git"),
    (re.compile(r"\bgit\s+(reset\s+--hard|clean|checkout\s+--\s|branch\s+-D)"), "throwing away local changes"),
    (re.compile(r"\bnpm\s+publish"), "publishing a package"),
    (re.compile(r"\b(pip\s+install|brew\s+(install|uninstall))"), "installing a package"),
    (re.compile(r"\bcurl\b.*\|\s*(ba)?sh"), "running a script off the internet"),
    (re.compile(r"\bsudo\b|\bchmod\s+777\b"), "a command that needs admin rights"),
    (re.compile(r"\b(mkfs|dd\s+if=|shutdown|killall|launchctl)\b"), "a system-level command"),
    (re.compile(r">\s*/(etc|usr|bin|sbin|System|Library)/"), "writing into a system folder"),
)


def spoken(tool: str, args: dict) -> str:
    """The half-sentence said out loud — no commands, no paths, no URLs."""
    if tool == "Bash":
        command = args.get("command", "")
        for pattern, phrase in SPOKEN:
            if pattern.search(command):
                return phrase
        return "running a command"
    if tool == "WebFetch":
        return "fetching a web page"
    if tool in ("Write", "Edit", "NotebookEdit"):
        return "editing a file outside the project"
    return f"a {tool} call"


def risk(tool: str, args: dict, cwd: str) -> str:
    """Return a short reason this call needs a human, or '' to let it through."""
    if tool == "Bash":
        command = args.get("command", "")
        if RISKY_BASH.search(command):
            return command.strip()[:120]
        return ""

    if tool in ("Write", "Edit", "NotebookEdit"):
        path = args.get("file_path") or args.get("notebook_path") or ""
        # Editing inside the project is the whole point; outside it is not.
        if path and not os.path.abspath(path).startswith(os.path.abspath(cwd)):
            return f"{tool} outside the project: {os.path.basename(path)}"
        return ""

    if tool == "WebFetch":
        return f"fetch {args.get('url', '')[:80]}"

    return ""


def ask(payload: dict) -> tuple[bool, str]:
    with socket.create_connection((HOST, PORT), timeout=5) as sock:
        sock.sendall((json.dumps(payload) + "\n").encode())
        sock.settimeout(TIMEOUT_S)
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
    answer = json.loads(buf or b"{}")
    return bool(answer.get("approved")), str(answer.get("reason", ""))


def main():
    try:
        event = json.load(sys.stdin)
    except Exception:
        return

    tool = event.get("tool_name", "")
    args = event.get("tool_input") or {}
    cwd = event.get("cwd") or os.getcwd()
    # Which agent is asking — several can be running under the notch at once.
    session_id = event.get("session_id", "")

    reason = risk(tool, args, cwd)
    if not reason:
        return

    try:
        approved, note = ask(
            {
                "tool": tool,
                "input": args,
                "reason": reason,
                "summary": spoken(tool, args),
                "cwd": cwd,
                "session_id": session_id,
            }
        )
    except Exception:
        # Backend gone or not answering: don't wedge the turn, let Claude Code decide.
        return

    decision = "allow" if approved else "deny"
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": note or ("approved by voice" if approved else "declined by voice"),
        }
    }
    print(json.dumps(out))


if __name__ == "__main__":
    main()
