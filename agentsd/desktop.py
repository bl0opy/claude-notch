"""What the Claude desktop app knows about its own Code sessions.

The app keeps one JSON file per session under its Application Support folder,
named by the session's id in the app (`local_…`, which the registry calls
`hostSessionId`). It carries the session's title, its permission mode, and a
one-line summary the app writes after every turn.

None of it is documented. A missing file or a renamed key only costs the notch
a nicer title and the summary line; the roster keeps working without them.
"""
import json
import os
from dataclasses import dataclass
from pathlib import Path

APP_SESSIONS = Path(
    os.getenv("CLAUDE_DESKTOP_SESSIONS", str(Path.home() / "Library/Application Support/Claude/claude-code-sessions"))
)
ENTRYPOINT = "claude-desktop"

_paths: dict[str, Path] = {}


@dataclass
class AppSession:
    title: str = ""
    permission_mode: str = ""
    # "added the settings page; tests pass" — what the last turn did.
    summary: str = ""
    # What it says it needs from you, if anything.
    needs: str = ""

    def as_dict(self) -> dict:
        return {
            "title": self.title,
            "permissionMode": self.permission_mode,
            "summary": self.summary,
            "needs": self.needs,
        }


def _find(host_session_id: str) -> Path | None:
    path = _paths.get(host_session_id)
    if path and path.exists():
        return path
    if not APP_SESSIONS.is_dir() or "/" in host_session_id:
        return None
    path = next(APP_SESSIONS.glob(f"*/*/{host_session_id}.json"), None)
    if path:
        _paths[host_session_id] = path
    return path


def app_session(host_session_id: str) -> AppSession | None:
    if not host_session_id:
        return None
    path = _find(host_session_id)
    if not path:
        return None
    try:
        raw = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    summary = raw.get("postTurnSummary") or {}
    if not isinstance(summary, dict):
        summary = {}
    return AppSession(
        title=str(raw.get("title") or ""),
        permission_mode=str(raw.get("permissionMode") or ""),
        summary=str(summary.get("status_detail") or ""),
        needs=str(summary.get("needs_action") or ""),
    )


def link(host_session_id: str) -> str:
    """Opens the app on that session."""
    return f"claude://code/continue?session={host_session_id}" if host_session_id else ""
