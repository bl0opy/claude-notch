import asyncio
import json
import os
import uuid
from typing import Any, AsyncIterator

from loguru import logger


class ClaudeCodeSession:
    """Long-lived `claude -p` subprocess speaking stream-json over stdin/stdout.

    One process for the whole app run, so context persists across turns.
    """

    def __init__(
        self,
        cwd: str,
        model: str = "",
        permission_mode: str = "acceptEdits",
        system_prompt: str | None = None,
    ):
        self.cwd = cwd
        self.model = model
        self.permission_mode = permission_mode
        self.system_prompt = system_prompt
        self.proc: asyncio.subprocess.Process | None = None
        self.events: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self.session_id: str | None = None
        self._block_types: dict[int, str] = {}
        self._reader_task: asyncio.Task | None = None
        self._stderr_task: asyncio.Task | None = None
        self._pending_control: dict[str, asyncio.Future] = {}

    def _argv(self) -> list[str]:
        argv = [
            "claude",
            "-p",
            "--verbose",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--include-partial-messages",
            "--permission-mode",
            self.permission_mode,
        ]
        if self.model:
            argv += ["--model", self.model]
        if self.system_prompt:
            argv += ["--append-system-prompt", self.system_prompt]
        return argv

    async def start(self):
        self.proc = await asyncio.create_subprocess_exec(
            *self._argv(),
            cwd=self.cwd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env={**os.environ, "CLAUDE_CODE_ENTRYPOINT": "voice-agent"},
        )
        self._reader_task = asyncio.create_task(self._read_stdout())
        self._stderr_task = asyncio.create_task(self._read_stderr())
        logger.info(f"claude code started (pid {self.proc.pid}) in {self.cwd}")

    async def stop(self):
        for task in (self._reader_task, self._stderr_task):
            if task:
                task.cancel()
        if self.proc and self.proc.returncode is None:
            try:
                self.proc.stdin.close()
            except Exception:
                pass
            try:
                await asyncio.wait_for(self.proc.wait(), timeout=3)
            except asyncio.TimeoutError:
                self.proc.kill()

    async def _write(self, obj: dict[str, Any]):
        if not self.proc or self.proc.stdin.is_closing():
            raise RuntimeError("claude code process is not running")
        self.proc.stdin.write((json.dumps(obj) + "\n").encode())
        await self.proc.stdin.drain()

    async def send_user_text(self, text: str):
        await self._write(
            {
                "type": "user",
                "message": {"role": "user", "content": [{"type": "text", "text": text}]},
            }
        )

    async def interrupt(self):
        """Ask Claude Code to abort the in-flight turn."""
        request_id = f"req_{uuid.uuid4().hex[:12]}"
        try:
            await self._write(
                {
                    "type": "control_request",
                    "request_id": request_id,
                    "request": {"subtype": "interrupt"},
                }
            )
            logger.info("sent interrupt to claude code")
        except Exception as e:
            logger.warning(f"interrupt failed: {e}")

    async def _read_stderr(self):
        assert self.proc
        while True:
            line = await self.proc.stderr.readline()
            if not line:
                break
            logger.warning(f"[claude stderr] {line.decode(errors='replace').rstrip()}")

    async def _read_stdout(self):
        assert self.proc
        while True:
            line = await self.proc.stdout.readline()
            if not line:
                await self.events.put({"kind": "process_exit"})
                break
            raw = line.decode(errors="replace").strip()
            if not raw:
                continue
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                logger.debug(f"non-json line from claude: {raw[:200]}")
                continue
            for event in self._translate(msg):
                await self.events.put(event)

    def _translate(self, msg: dict[str, Any]) -> list[dict[str, Any]]:
        mtype = msg.get("type")

        if mtype == "system" and msg.get("subtype") == "init":
            self.session_id = msg.get("session_id")
            return [{"kind": "ready", "session_id": self.session_id}]

        if mtype == "stream_event":
            return self._translate_stream_event(msg.get("event", {}))

        if mtype == "assistant":
            out = []
            for block in msg.get("message", {}).get("content", []):
                if block.get("type") == "tool_use":
                    out.append(
                        {
                            "kind": "tool_use",
                            "name": block.get("name", "tool"),
                            "input": block.get("input", {}),
                        }
                    )
            return out

        if mtype == "result":
            return [
                {
                    "kind": "turn_end",
                    "text": msg.get("result", ""),
                    "is_error": msg.get("is_error", False),
                    "duration_ms": msg.get("duration_ms"),
                }
            ]

        return []

    def _translate_stream_event(self, event: dict[str, Any]) -> list[dict[str, Any]]:
        etype = event.get("type")

        if etype == "message_start":
            self._block_types.clear()
            return [{"kind": "turn_start"}]

        if etype == "content_block_start":
            idx = event.get("index", 0)
            btype = event.get("content_block", {}).get("type", "")
            self._block_types[idx] = btype
            if btype == "thinking":
                return [{"kind": "thinking_start"}]
            return []

        if etype == "content_block_delta":
            idx = event.get("index", 0)
            delta = event.get("delta", {})
            if self._block_types.get(idx) == "text" and delta.get("type") == "text_delta":
                return [{"kind": "text_delta", "text": delta.get("text", "")}]
            return []

        if etype == "message_stop":
            return [{"kind": "message_stop"}]

        return []

    async def stream(self) -> AsyncIterator[dict[str, Any]]:
        while True:
            yield await self.events.get()
