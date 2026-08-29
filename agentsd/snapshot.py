"""One tick's view of every agent on the machine, in the shape the notch reads."""
import subprocess
import time
from pathlib import Path

from agentsd.config import config
from agentsd.registry import LiveSession, live_sessions
from agentsd.transcripts import Transcripts

_toplevel: dict[str, str] = {}


def project_name(cwd: str) -> str:
    """Repo name where there is one — a session's cwd is often a subdirectory."""
    if cwd not in _toplevel:
        try:
            out = subprocess.run(
                ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                capture_output=True, timeout=5, text=True,
            )
            root = out.stdout.strip() if out.returncode == 0 else ""
        except (OSError, subprocess.SubprocessError):
            root = ""
        _toplevel[cwd] = Path(root or cwd).name
    return _toplevel[cwd]


def _row(session: LiveSession, transcripts: Transcripts, owned: set[str]) -> dict:
    rollup = transcripts.rollup(session.cwd, session.session_id).as_dict()
    if not config.send_details:
        rollup["activityDetail"] = ""
    return {
        "id": session.session_id,
        "pid": session.pid,
        "name": session.name,
        "project": project_name(session.cwd),
        "cwd": session.cwd,
        "state": session.state,
        "waitingFor": session.waiting_for,
        "reachable": session.reachable,
        "owned": session.session_id in owned,
        **rollup,
    }


def build(transcripts: Transcripts, owned: set[str] | None = None) -> dict:
    sessions, degraded = live_sessions()
    owned = owned or set()
    rows = [_row(s, transcripts, owned) for s in sessions]
    version = next((s.version for s in sessions if s.version), "")
    return {
        "type": "agents",
        "ts": int(time.time() * 1000),
        "degraded": bool(degraded),
        "reason": degraded,
        "cliVersion": version,
        "list": rows,
    }
