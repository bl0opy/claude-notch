"""One tick's view of every agent on the machine, in the shape the notch reads."""
import subprocess
import time
from pathlib import Path

from agentsd.config import config
from agentsd.registry import LiveSession, live_sessions
from agentsd.transcripts import Transcripts

_toplevel: dict[str, str] = {}
_hosts: dict[int, tuple[str, str]] = {}

# Ancestor process name -> the app the notch brings forward to show a session.
_HOST_APPS = {
    "Terminal": "Terminal",
    "iTerm2": "iTerm2",
    "Code Helper": "Code",
    "Code": "Code",
    "Electron": "Code",
    "Cursor Helper": "Cursor",
    "Cursor": "Cursor",
    "ghostty": "Ghostty",
    "wezterm-gui": "WezTerm",
    "Warp": "Warp",
}


def _ps(pid: int) -> tuple[int, str, str]:
    out = subprocess.run(
        ["ps", "-o", "ppid=,tty=,comm=", "-p", str(pid)],
        capture_output=True, timeout=5, text=True,
    ).stdout.strip()
    ppid, tty, comm = (out.split(None, 2) + ["", "", ""])[:3]
    return int(ppid or 0), tty, Path(comm).name


def host_of(pid: int) -> tuple[str, str]:
    """(tty, app) a session lives in, e.g. ("ttys003", "Terminal"). Blank when unknown."""
    if pid not in _hosts:
        tty, app = "", ""
        try:
            parent, tty, _ = _ps(pid)
            for _ in range(12):
                if parent <= 1:
                    break
                grandparent, _, comm = _ps(parent)
                if comm in _HOST_APPS:
                    app = _HOST_APPS[comm]
                    break
                parent = grandparent
        except (OSError, subprocess.SubprocessError, ValueError):
            pass
        _hosts[pid] = ("" if tty in ("", "??") else tty, app)
    return _hosts[pid]


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
    tty, host = host_of(session.pid)
    return {
        "id": session.session_id,
        "tty": tty,
        "host": host,
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
