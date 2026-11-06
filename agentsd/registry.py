"""Which Claude Code sessions are alive right now, and what they're doing.

`claude agents --json` is the supported way to ask; `~/.claude/sessions/<pid>.json`
is undocumented but carries the two fields the dashboard exists for — `status`
and `waitingFor` — so it enriches each row where it can and never replaces it.
"""
import json
import os
import subprocess
from dataclasses import dataclass

from loguru import logger

from agentsd import paths

# Claude Code's own vocabulary, mapped to the notch's. Anything unrecognised
# stays "unknown" — a wrong state is worse than an honest blank.
_STATES = {"busy": "working", "waiting": "waiting", "idle": "idle"}

_warned: set[str] = set()


def _warn_once(key: str, message: str):
    if key not in _warned:
        _warned.add(key)
        logger.warning(message)


@dataclass
class LiveSession:
    session_id: str
    pid: int
    cwd: str
    name: str = ""
    state: str = "unknown"
    waiting_for: str = ""
    socket_path: str = ""
    version: str = ""
    started_at: int = 0
    updated_at: int = 0
    # "claude-desktop" for a Code tab in the Claude app; its id there is
    # host_session_id ("local_…"), which is what the app's links take.
    entrypoint: str = ""
    host_session_id: str = ""

    @property
    def reachable(self) -> bool:
        return bool(self.socket_path)


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, ValueError):
        return False
    except PermissionError:
        return True
    return True


def from_cli() -> list[dict]:
    try:
        out = subprocess.run(
            ["claude", "agents", "--json"], capture_output=True, timeout=10, text=True
        )
    except (OSError, subprocess.SubprocessError) as e:
        _warn_once("cli", f"`claude agents --json` unavailable ({e}) — falling back to the registry")
        return []
    if out.returncode != 0:
        _warn_once("cli-rc", f"`claude agents --json` exited {out.returncode}")
        return []
    try:
        rows = json.loads(out.stdout or "[]")
    except json.JSONDecodeError:
        _warn_once("cli-json", "`claude agents --json` printed something that isn't JSON")
        return []
    return [r for r in rows if isinstance(r, dict)]


def from_registry() -> dict[int, dict]:
    rows: dict[int, dict] = {}
    for path in paths.session_files():
        try:
            row = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        pid = row.get("pid")
        if isinstance(pid, int):
            rows[pid] = row
    return rows


def live_sessions() -> tuple[list[LiveSession], str]:
    """Returns the roster and, if something had to be guessed, why."""
    registry = from_registry()
    listed = from_cli()
    degraded = ""

    if not listed:
        listed = [dict(r) for r in registry.values()]
        degraded = "no session list from the cli"
    if not registry:
        degraded = "no session registry"

    sessions = []
    for row in listed:
        pid = row.get("pid")
        session_id = row.get("sessionId") or ""
        cwd = row.get("cwd") or ""
        if not isinstance(pid, int) or not session_id or not cwd:
            continue
        if not _alive(pid):
            # Registry files survive a kill -9; the process is the truth.
            continue

        extra = registry.get(pid, {})
        status = extra.get("status") or row.get("status") or ""
        if status and status not in _STATES:
            _warn_once(f"status:{status}", f"unknown session status {status!r} — showing it as unknown")

        sessions.append(
            LiveSession(
                session_id=session_id,
                pid=pid,
                cwd=cwd,
                name=extra.get("name") or row.get("name") or "",
                state=_STATES.get(status, "unknown"),
                waiting_for=extra.get("waitingFor") or "",
                socket_path=extra.get("messagingSocketPath") or "",
                version=extra.get("version") or "",
                started_at=int(extra.get("startedAt") or row.get("startedAt") or 0),
                updated_at=int(extra.get("updatedAt") or 0),
                entrypoint=extra.get("entrypoint") or row.get("entrypoint") or "",
                host_session_id=extra.get("hostSessionId") or "",
            )
        )
    return sessions, degraded
