"""Claude Code sessions the daemon runs itself, each in a pty it owns.

These are the real interactive `claude`, full TUI and all, with no terminal
window around them: the window (agentsd/window.py) draws the pty, and anything
typed there, said to the notch, or sent from the notch goes into the same pty.
The daemon owns them rather than the voice backend so they outlive it.

Each session is started with `--session-id`, so it has its real id from the
first byte — no pid placeholder waiting on the registry. A session that stops
(or was running when the daemon last exited) stays listed, and resuming it is
`claude --resume <id>` in the same pty slot.
"""
import asyncio
import codecs
import fcntl
import json
import os
import shutil
import signal
import struct
import subprocess
import termios
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from loguru import logger

STATE_FILE = Path.home() / "Library" / "Application Support" / "notch-agent" / "hosted.json"
# Characters of output kept per session, replayed to a window that attaches
# late. The TUI redraws on the resize every attach sends, so this only has to
# cover the scrollback above the live screen.
SCROLLBACK = 400_000
KEEP_STOPPED = 20
# Claude Code reads a burst of text ending in a return as a paste, which puts
# the return in the prompt instead of submitting it. A beat between the two
# makes it a keypress.
SUBMIT_DELAY_S = 0.08
ESC = "\x1b"

Listener = Callable[[dict], None]

# What a running Claude Code session sets for the processes under it. Started
# from inside one (a daemon launched from a Claude Code shell, say), a new
# session would take itself for that one's child: no transcript, no registry
# entry, someone else's messaging socket.
INHERITED = {
    "CLAUDECODE",
    "CLAUDE_PID",
    "CLAUDE_EFFORT",
    "CLAUDE_CODE_CHILD_SESSION",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_EXECPATH",
    "CLAUDE_CODE_MESSAGING_SOCKET",
    "CLAUDE_CODE_MESSAGING_TOKEN",
    "CLAUDE_CODE_SESSION_ATTENDED",
    "CLAUDE_CODE_SESSION_ID",
}


def session_env(**extra: str) -> dict[str, str]:
    """The environment for a new top-level Claude Code session."""
    env = {k: v for k, v in os.environ.items() if k not in INHERITED}
    return {**env, **extra}


def _set_ctty():
    # Runs in the child after setsid: make the pty its controlling terminal,
    # which is what gets it SIGWINCH on a resize and ^C as a signal.
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


def _winsize(fd: int, cols: int, rows: int):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


@dataclass
class Hosted:
    id: str
    cwd: str
    started_at: float = field(default_factory=time.time)
    pid: int = 0
    exit_code: int | None = None
    proc: subprocess.Popen | None = None
    fd: int = -1
    scrollback: str = ""
    cols: int = 120
    rows: int = 36
    listeners: set = field(default_factory=set)
    _decoder: codecs.IncrementalDecoder = field(
        default_factory=lambda: codecs.getincrementaldecoder("utf-8")(errors="replace")
    )

    @property
    def running(self) -> bool:
        return self.fd >= 0

    def as_dict(self) -> dict:
        return {
            "id": self.id,
            "cwd": self.cwd,
            "pid": self.pid,
            "running": self.running,
            "exitCode": self.exit_code,
            "startedAt": int(self.started_at * 1000),
        }


class PtyHost:
    def __init__(self, argv: list[str] | None = None, state_file: Path | None = STATE_FILE):
        # argv replaces `claude` for tests; the session flags are still appended.
        self._argv = argv
        self._state_file = state_file
        self.sessions: dict[str, Hosted] = {}
        self.on_change: Callable[[], None] | None = None
        self._load()

    # ---- persistence ------------------------------------------------------

    def _load(self):
        if not self._state_file or not self._state_file.exists():
            return
        try:
            rows = json.loads(self._state_file.read_text())
        except (OSError, json.JSONDecodeError):
            return
        for row in rows:
            if row.get("id") and row.get("cwd"):
                self.sessions[row["id"]] = Hosted(
                    id=row["id"], cwd=row["cwd"], started_at=row.get("startedAt", 0) / 1000
                )

    def _save(self):
        if not self._state_file:
            return
        rows = sorted(self.sessions.values(), key=lambda h: h.started_at, reverse=True)
        payload = [{"id": h.id, "cwd": h.cwd, "startedAt": int(h.started_at * 1000)} for h in rows]
        try:
            self._state_file.parent.mkdir(parents=True, exist_ok=True)
            self._state_file.write_text(json.dumps(payload, indent=2))
        except OSError as e:
            logger.warning(f"could not save hosted sessions: {e}")

    def _changed(self):
        self._save()
        if self.on_change:
            self.on_change()

    # ---- lifecycle --------------------------------------------------------

    def snapshot(self) -> dict:
        rows = sorted(self.sessions.values(), key=lambda h: h.started_at, reverse=True)
        return {"type": "hosted", "list": [h.as_dict() for h in rows]}

    def running_ids(self) -> set[str]:
        return {h.id for h in self.sessions.values() if h.running}

    def spawn(self, cwd: str, cols: int = 120, rows: int = 36) -> Hosted:
        cwd = os.path.abspath(os.path.expanduser(cwd))
        if not os.path.isdir(cwd):
            raise ValueError(f"not a directory: {cwd}")
        hosted = Hosted(id=str(uuid.uuid4()), cwd=cwd, cols=cols, rows=rows)
        self.sessions[hosted.id] = hosted
        self._start(hosted, ["--session-id", hosted.id])
        self._trim()
        self._changed()
        return hosted

    def resume(self, session_id: str) -> Hosted:
        hosted = self.sessions.get(session_id)
        if not hosted:
            raise KeyError(session_id)
        if hosted.running:
            return hosted
        hosted.exit_code = None
        hosted.scrollback = ""
        self._start(hosted, ["--resume", hosted.id])
        self._changed()
        return hosted

    def _command(self) -> list[str]:
        if self._argv:
            return list(self._argv)
        claude = shutil.which("claude")
        if not claude:
            raise RuntimeError("claude isn't on PATH for the agents daemon")
        return [claude]

    def _start(self, hosted: Hosted, flags: list[str]):
        argv = self._command() + flags
        master, slave = os.openpty()
        _winsize(master, hosted.cols, hosted.rows)
        env = session_env(TERM="xterm-256color", COLORTERM="truecolor")
        try:
            proc = subprocess.Popen(
                argv,
                cwd=hosted.cwd,
                env=env,
                stdin=slave,
                stdout=slave,
                stderr=slave,
                start_new_session=True,
                preexec_fn=_set_ctty,
                close_fds=True,
            )
        except OSError:
            os.close(master)
            os.close(slave)
            raise
        os.close(slave)
        os.set_blocking(master, False)
        hosted.proc, hosted.pid, hosted.fd = proc, proc.pid, master
        hosted.started_at = time.time()
        asyncio.get_running_loop().add_reader(master, self._on_readable, hosted)
        logger.info(f"hosted session {hosted.id[:8]} started in {hosted.cwd} (pid {proc.pid})")

    def _trim(self):
        stopped = sorted(
            (h for h in self.sessions.values() if not h.running),
            key=lambda h: h.started_at,
            reverse=True,
        )
        for old in stopped[KEEP_STOPPED:]:
            del self.sessions[old.id]

    def _on_readable(self, hosted: Hosted):
        try:
            data = os.read(hosted.fd, 65536)
        except BlockingIOError:
            return
        except OSError:
            # macOS reports a closed slave as EIO rather than EOF.
            data = b""
        if not data:
            self._reap(hosted)
            return
        text = hosted._decoder.decode(data)
        if not text:
            return
        hosted.scrollback = (hosted.scrollback + text)[-SCROLLBACK:]
        self._emit(hosted, {"type": "out", "data": text})

    def _reap(self, hosted: Hosted):
        loop = asyncio.get_running_loop()
        loop.remove_reader(hosted.fd)
        os.close(hosted.fd)
        hosted.fd = -1
        code = None
        if hosted.proc:
            try:
                code = hosted.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                hosted.proc.kill()
                code = hosted.proc.wait()
        hosted.exit_code = code
        hosted.proc = None
        logger.info(f"hosted session {hosted.id[:8]} exited ({code})")
        self._emit(hosted, {"type": "exit", "code": code})
        self._changed()

    def _emit(self, hosted: Hosted, frame: dict):
        for listener in list(hosted.listeners):
            listener(frame)

    # ---- input ------------------------------------------------------------

    def write(self, session_id: str, data: str):
        hosted = self.sessions.get(session_id)
        if not hosted or not hosted.running:
            return
        payload = data.encode()
        while payload:
            try:
                sent = os.write(hosted.fd, payload)
            except BlockingIOError:
                # The pty's input buffer is full; a paste that big is rare
                # enough to wait out rather than queue.
                time.sleep(0.01)
                continue
            except OSError:
                return
            payload = payload[sent:]

    def resize(self, session_id: str, cols: int, rows: int):
        hosted = self.sessions.get(session_id)
        if not hosted or cols <= 0 or rows <= 0:
            return
        hosted.cols, hosted.rows = cols, rows
        if hosted.running:
            _winsize(hosted.fd, cols, rows)

    async def type(self, session_id: str, text: str):
        """Put a line in the prompt and submit it, as if typed."""
        text = " ".join(text.split())
        if not text:
            return
        self.write(session_id, text)
        await asyncio.sleep(SUBMIT_DELAY_S)
        self.write(session_id, "\r")

    def interrupt(self, session_id: str):
        self.write(session_id, ESC)

    def stop(self, session_id: str):
        hosted = self.sessions.get(session_id)
        if not hosted or not hosted.proc:
            return
        try:
            os.killpg(hosted.pid, signal.SIGHUP)
        except (ProcessLookupError, PermissionError):
            pass

    def forget(self, session_id: str):
        hosted = self.sessions.get(session_id)
        if hosted and not hosted.running:
            del self.sessions[session_id]
            self._changed()

    def attach(self, session_id: str, listener: Listener) -> Hosted | None:
        hosted = self.sessions.get(session_id)
        if hosted:
            hosted.listeners.add(listener)
        return hosted

    def detach(self, session_id: str, listener: Listener):
        hosted = self.sessions.get(session_id)
        if hosted:
            hosted.listeners.discard(listener)

    async def shutdown(self):
        for hosted in self.sessions.values():
            if hosted.running:
                self.stop(hosted.id)
        self._save()
