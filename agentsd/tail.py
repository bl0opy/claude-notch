"""Reads what a session says as it says it, for agents we don't drive.

An owned session streams its answer to us over stdout. A foreign one doesn't —
the only place its words appear is its transcript, so a focused foreign agent is
read from the tail of that file.
"""
import json
from pathlib import Path


class TranscriptTail:
    """New assistant text since the last poll, and whether the turn ended."""

    def __init__(self, path: Path, from_start: bool = False):
        self.path = path
        self._offset = 0
        self._inode = None
        if not from_start:
            try:
                stat = path.stat()
                self._offset, self._inode = stat.st_size, stat.st_ino
            except OSError:
                pass

    def poll(self) -> tuple[list[str], bool]:
        try:
            stat = self.path.stat()
        except OSError:
            return [], False

        if self._inode is not None and stat.st_ino != self._inode:
            self._offset, self._inode = 0, stat.st_ino
        elif stat.st_size < self._offset:
            self._offset = 0
        self._inode = stat.st_ino
        if stat.st_size == self._offset:
            return [], False

        try:
            with self.path.open() as handle:
                handle.seek(self._offset)
                chunk = handle.read()
                self._offset = handle.tell()
        except OSError:
            return [], False

        said, ended = [], False
        for line in chunk.splitlines():
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("type") == "system" and row.get("subtype") == "turn_duration":
                ended = True
            if row.get("type") != "assistant":
                continue
            for block in (row.get("message") or {}).get("content") or []:
                if isinstance(block, dict) and block.get("type") == "text" and block.get("text"):
                    said.append(block["text"])
        return said, ended
