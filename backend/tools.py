"""How a tool call is described out loud and on screen.

Shared so an agent the notch merely watches gets narrated in the same words as
the one it is driving.
"""
import os

_TOOL_NARRATION = {
    "Read": "reading",
    "Edit": "editing",
    "Write": "writing",
    "Bash": "running a command",
    "Grep": "searching",
    "Glob": "looking for files",
    "Task": "spawning a subagent",
    "WebFetch": "fetching a page",
    "WebSearch": "searching the web",
}

# The argument worth showing for each tool, in priority order — the same thing
# Claude Code puts in parentheses after the tool name.
_TOOL_ARGS = {
    "Read": ("file_path",),
    "Edit": ("file_path",),
    "Write": ("file_path",),
    "NotebookEdit": ("notebook_path",),
    "Bash": ("command",),
    "Grep": ("pattern",),
    "Glob": ("pattern",),
    "Task": ("description",),
    "WebFetch": ("url",),
    "WebSearch": ("query",),
    "Skill": ("skill",),
}


def _tool_detail(name: str, args: dict) -> str:
    """One-line argument summary, paths shortened to a basename."""
    keys = _TOOL_ARGS.get(name) or tuple(args)[:1]
    for key in keys:
        value = args.get(key)
        if not isinstance(value, str) or not value:
            continue
        if key.endswith("path"):
            value = os.path.basename(value) or value
        return " ".join(value.split())[:80]
    return ""
