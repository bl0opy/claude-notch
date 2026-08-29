"""Rolls a session's transcript up into the numbers a row needs.

Files are append-only, but re-reading one whole is cheap enough not to bother
tracking byte offsets: the largest transcript on this machine (17.8 MB) parses
in 39 ms. So the cache is keyed on (mtime, size) and an untouched file costs a
single stat.
"""
import json
import time
from dataclasses import dataclass, field
from pathlib import Path

from agentsd import paths
from agentsd.usage import Totals, fold
from backend.tools import _tool_detail


@dataclass
class Rollup:
    totals: Totals = field(default_factory=Totals)
    model: str = ""
    branch: str = ""
    activity: str = ""
    activity_detail: str = ""
    subagents_total: int = 0
    subagents_active: int = 0

    def as_dict(self) -> dict:
        return {
            "model": self.model,
            "branch": self.branch,
            "activity": self.activity,
            "activityDetail": self.activity_detail,
            "subagents": {"total": self.subagents_total, "active": self.subagents_active},
            "tokens": self.totals.as_dict(),
        }


@dataclass
class _Parsed:
    totals: Totals = field(default_factory=Totals)
    model: str = ""
    branch: str = ""
    activity: str = ""
    activity_detail: str = ""


def _parse(path: Path) -> _Parsed:
    out = _Parsed()
    try:
        handle = path.open()
    except OSError:
        return out

    with handle:
        for line in handle:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue

            branch = row.get("gitBranch")
            # "HEAD" is what a detached or non-repo cwd reports; not worth showing.
            if branch and branch != "HEAD":
                out.branch = branch

            if row.get("type") != "assistant":
                continue

            message = row.get("message") or {}
            fold(message.get("usage") or {}, out.totals)
            if message.get("model"):
                out.model = message["model"]

            for block in message.get("content") or []:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    out.activity = block.get("name") or ""
                    out.activity_detail = _tool_detail(out.activity, block.get("input") or {})
    return out


class Transcripts:
    def __init__(self, subagent_active_window_s: float = 10.0):
        self._cache: dict[Path, tuple[float, int, _Parsed]] = {}
        self._window = subagent_active_window_s

    def _parsed(self, path: Path) -> _Parsed | None:
        try:
            stat = path.stat()
        except OSError:
            self._cache.pop(path, None)
            return None
        cached = self._cache.get(path)
        if cached and cached[0] == stat.st_mtime and cached[1] == stat.st_size:
            return cached[2]
        parsed = _parse(path)
        self._cache[path] = (stat.st_mtime, stat.st_size, parsed)
        return parsed

    def rollup(self, cwd: str, session_id: str, now: float | None = None) -> Rollup:
        now = time.time() if now is None else now
        result = Rollup()

        main = self._parsed(paths.transcript(cwd, session_id))
        if main:
            result.totals = Totals(**vars(main.totals))
            result.model = main.model
            result.branch = main.branch
            result.activity = main.activity
            result.activity_detail = main.activity_detail

        for path in paths.subagent_files(cwd, session_id):
            parsed = self._parsed(path)
            if not parsed:
                continue
            result.subagents_total += 1
            try:
                if now - path.stat().st_mtime <= self._window:
                    result.subagents_active += 1
            except OSError:
                pass
            fold_totals(result.totals, parsed.totals)
        return result

    def forget(self, keep: set[Path]):
        for path in list(self._cache):
            if path not in keep:
                del self._cache[path]


def fold_totals(acc: Totals, other: Totals):
    acc.tokens_in += other.tokens_in
    acc.tokens_out += other.tokens_out
    acc.cache_read += other.cache_read
    acc.cache_write += other.cache_write
    acc.thinking += other.thinking
