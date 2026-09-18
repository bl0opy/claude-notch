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
from agentsd.usage import Totals, cost, fold, occupancy, window_for
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
    # How full this session's window is right now, from its last request.
    context: int = 0
    # Priced as it is accumulated: a subagent can be on a different model from
    # its parent, so the parent's rate can't be applied to the folded total.
    cost: float = 0.0

    @property
    def window(self) -> int:
        return window_for(self.model)

    def as_dict(self) -> dict:
        return {
            "model": self.model,
            "branch": self.branch,
            "activity": self.activity,
            "activityDetail": self.activity_detail,
            "subagents": {"total": self.subagents_total, "active": self.subagents_active},
            "tokens": self.totals.as_dict(),
            "context": {
                "used": self.context,
                "window": self.window,
                "pct": round(100 * self.context / self.window, 1) if self.window else 0.0,
            },
            "cost": round(self.cost, 4),
        }


@dataclass
class _Parsed:
    totals: Totals = field(default_factory=Totals)
    model: str = ""
    branch: str = ""
    activity: str = ""
    activity_detail: str = ""
    context: int = 0


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
            usage = message.get("usage") or {}
            fold(usage, out.totals)
            # Last one wins: the newest request is the conversation's size now.
            if usage:
                out.context = occupancy(usage)
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
            # Subagents have windows of their own, so this stays the main one's.
            result.context = main.context
            result.cost = cost(main.totals, main.model)

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
            result.cost += cost(parsed.totals, parsed.model or result.model)
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
