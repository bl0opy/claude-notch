"""Every path under ~/.claude is named here and nowhere else.

`sessions/<pid>.<hash>.key` holds a peer auth token, `ide/*.lock` holds an IDE
token, and `daemon/` and `.credentials.json` hold secrets — none of them are
reachable through anything in this module.
"""
import os
from pathlib import Path

CLAUDE_HOME = Path(os.getenv("CLAUDE_HOME", str(Path.home() / ".claude")))
SESSIONS_DIR = CLAUDE_HOME / "sessions"
PROJECTS_DIR = CLAUDE_HOME / "projects"


def session_files() -> list[Path]:
    """The live-session registry — one file per running session, `*.json` only."""
    if not SESSIONS_DIR.is_dir():
        return []
    return sorted(SESSIONS_DIR.glob("*.json"))


def slug(cwd: str) -> str:
    """Project directory name Claude Code derives from a cwd.

    Lossy — a literal '-' in a path is indistinguishable from a '/' — so this
    only ever runs forwards, from a cwd the registry gave us.
    """
    return cwd.replace("/", "-").replace(".", "-")


def transcript(cwd: str, session_id: str) -> Path:
    return PROJECTS_DIR / slug(cwd) / f"{session_id}.jsonl"


def subagent_files(cwd: str, session_id: str) -> list[Path]:
    """Subagent turns live in their own tree; a single-level glob misses them."""
    root = PROJECTS_DIR / slug(cwd) / session_id / "subagents"
    if not root.is_dir():
        return []
    return sorted(root.glob("agent-*.jsonl"))
