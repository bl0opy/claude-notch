"""Reads what a session says as it says it, for agents we don't drive.

An owned session streams its answer to us over stdout. A foreign one doesn't —
the only place its words appear is its transcript, so a focused foreign agent is
read from the tail of that file.

Two things about the file shape matter, both measured on this machine across the
40 largest transcripts:

1. **One assistant message is written as one row per content block.** 63.5% of
   message ids span more than one row, and the common shapes are
   `[thinking][text][tool_use]` and `[text][tool_use]`. So a `text` block in the
   middle of a turn is the agent's running commentary — "let me check the
   config" — not its answer. Speaking those burns the turn's two-sentence budget
   on mumbling and the real answer never gets said. `answer` is therefore only
   the text that follows the last tool call; everything before it is shown and
   not spoken.
2. **A read can land mid-write.** Only whole lines are consumed; a trailing
   partial line stays in the buffer for the next poll rather than being dropped
   as bad JSON with the offset already moved past it.
"""
import json
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Poll:
    said: list[str] = field(default_factory=list)  # new text, for display
    answer: str = ""                               # what to speak; set when ended
    ended: bool = False


class TranscriptTail:
    def __init__(self, path: Path, from_start: bool = False):
        self.path = path
        self._offset = 0
        self._inode = None
        self._carry = b""
        # Text blocks of the turn in progress, and where the last tool call fell.
        self._turn: list[str] = []
        self._since_tool = 0
        self._seen: set[tuple[str, int]] = set()
        if not from_start:
            try:
                stat = path.stat()
                self._offset, self._inode = stat.st_size, stat.st_ino
            except OSError:
                pass

    def poll(self) -> Poll:
        out = Poll()
        try:
            stat = self.path.stat()
        except OSError:
            return out

        if self._inode is not None and stat.st_ino != self._inode:
            self._offset, self._inode, self._carry = 0, stat.st_ino, b""
        elif stat.st_size < self._offset:
            self._offset, self._carry = 0, b""
        self._inode = stat.st_ino
        if stat.st_size == self._offset:
            return out

        try:
            with self.path.open("rb") as handle:
                handle.seek(self._offset)
                chunk = handle.read()
                self._offset = handle.tell()
        except OSError:
            return out

        buffer = self._carry + chunk
        # Whatever follows the last newline is a half-written line; keep it.
        cut = buffer.rfind(b"\n") + 1
        self._carry, buffer = buffer[cut:], buffer[:cut]

        for raw in buffer.decode("utf-8", "replace").splitlines():
            try:
                row = json.loads(raw)
            except json.JSONDecodeError:
                continue

            if row.get("type") == "system" and row.get("subtype") == "turn_duration":
                out.ended = True
                out.answer = "".join(self._turn[self._since_tool:]).strip()
                self._turn, self._since_tool = [], 0
                continue

            if row.get("type") != "assistant":
                continue

            message = row.get("message") or {}
            mid = message.get("id") or ""
            for block in message.get("content") or []:
                if not isinstance(block, dict):
                    continue
                kind = block.get("type")
                if kind == "tool_use":
                    # Anything said before this was commentary about the work.
                    self._since_tool = len(self._turn)
                elif kind == "text" and block.get("text"):
                    # A block can be rewritten on a later row under the same
                    # message id; say it once. Keying on position would not do
                    # it — rows carry one block each, so every index is 0.
                    key = (mid, block["text"])
                    if mid and key in self._seen:
                        continue
                    self._seen.add(key)
                    out.said.append(block["text"])
                    self._turn.append(block["text"])
        return out
