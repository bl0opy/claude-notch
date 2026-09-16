"""What a pending tool call is, in words — shared by the hook, the inbox and voice.

Stdlib only: `hooks/notch_hook.py` is copied into ~/.claude/hooks and runs under
the system python, so it inlines its own copy of `needs_asking`. Keep the two in
step.
"""
import json
import os
import re
from urllib.parse import urlparse

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

# The verb phrase that follows "<project> wants to ___". No commands, paths or
# URLs — the notch shows those.
SPOKEN_BASH = (
    (re.compile(r"\brm\s+(-\w*\s+)*-\w*[rf]"), "delete some files"),
    (re.compile(r"\bgit\s+push"), "push to git"),
    (re.compile(r"\bgit\s+(reset\s+--hard|clean|checkout\s+--\s|branch\s+-D)"), "throw away local changes"),
    (re.compile(r"\bnpm\s+publish"), "publish a package"),
    (re.compile(r"\b(pip\s+install|brew\s+(install|uninstall))"), "install a package"),
    (re.compile(r"\bcurl\b.*\|\s*(ba)?sh"), "run a script off the internet"),
    (re.compile(r"\bsudo\b|\bchmod\s+777\b"), "run something as admin"),
    (re.compile(r"\b(mkfs|dd\s+if=|shutdown|killall|launchctl)\b"), "run a system-level command"),
    (re.compile(r">\s*/(etc|usr|bin|sbin|System|Library)/"), "write into a system folder"),
)

_FILE_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit", "Read")


def _path(args: dict) -> str:
    return args.get("file_path") or args.get("notebook_path") or args.get("path") or ""


def destructive(tool: str, args: dict) -> bool:
    """Calls that voice can't wave through with a bare "yes"."""
    return tool == "Bash" and bool(RISKY_BASH.search(args.get("command", "")))


def detail(tool: str, args: dict) -> str:
    """The one line the notch shows: the command, the path, the URL."""
    if tool == "Bash":
        return " ".join(args.get("command", "").split())[:400]
    if tool in _FILE_TOOLS:
        return _path(args)
    if tool == "WebFetch":
        return args.get("url", "")
    try:
        return json.dumps(args, separators=(",", ":"))[:400]
    except (TypeError, ValueError):
        return ""


def summary(tool: str, args: dict) -> str:
    if tool == "Bash":
        command = args.get("command", "")
        for pattern, phrase in SPOKEN_BASH:
            if pattern.search(command):
                return phrase
        words = command.split()
        return f"run {os.path.basename(words[0])}" if words else "run a command"
    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        name = os.path.basename(_path(args))
        return f"edit {name}" if name else "edit a file"
    if tool == "Read":
        name = os.path.basename(_path(args))
        return f"read {name}" if name else "read a file"
    if tool == "WebFetch":
        host = urlparse(args.get("url", "")).hostname
        return f"fetch {host}" if host else "fetch a web page"
    if tool.startswith("mcp__"):
        return f"use {tool.rsplit('__', 1)[-1].replace('_', ' ')}"
    return f"use {tool}"
