import asyncio
import os
import re

from loguru import logger
from pipecat.frames.frames import (
    CancelFrame,
    EndFrame,
    Frame,
    InterruptionFrame,
    LLMFullResponseEndFrame,
    LLMFullResponseStartFrame,
    LLMTextFrame,
    StartFrame,
    TranscriptionFrame,
    UserStartedSpeakingFrame,
)
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from backend.approvals import ApprovalServer
from backend.bridge import NotchBridge
from backend.claude_code import ClaudeCodeSession
from backend.speech import SpeechFilter

_TOOL_NARRATION = {
    "Read": "reading",
    "Edit": "editing",
    "Write": "writing",
    "Bash": "running a command",
    "Grep": "searching",
    "Glob": "looking for files",
    "Task": "spawning a subagent",
    "WebFetch": "fetching a page",
    "WebSearch": "searching the web",
}

# The argument worth showing for each tool, in priority order — the same thing
# Claude Code puts in parentheses after the tool name.
_TOOL_ARGS = {
    "Read": ("file_path",),
    "Edit": ("file_path",),
    "Write": ("file_path",),
    "NotebookEdit": ("notebook_path",),
    "Bash": ("command",),
    "Grep": ("pattern",),
    "Glob": ("pattern",),
    "Task": ("description",),
    "WebFetch": ("url",),
    "WebSearch": ("query",),
    "Skill": ("skill",),
}


_YES = {"yes","yeah","yep","yup","sure","ok","okay","go","go ahead","do it","approve",
        "approved","allow","fine","please do","affirmative","sounds good","confirm"}
_NO = {"no","nope","nah","stop","don't","dont","cancel","deny","denied","reject","abort",
       "negative","skip","never mind","nevermind"}


def hears_approval(text: str) -> bool | None:
    """yes/no from a spoken reply, or None if it isn't an answer either way."""
    words = re.findall(r"[a-z']+", text.lower())
    if not words:
        return None
    phrase = " ".join(words)
    # Check the leading words first — "no, wait" is a no even though it's long.
    for n in (3, 2, 1):
        head = " ".join(words[:n])
        if head in _NO:
            return False
        if head in _YES:
            return True
    if any(w in _NO for w in words) and not any(w in _YES for w in words):
        return False
    if any(w in _YES for w in words) and not any(w in _NO for w in words):
        return True
    return None


def _tool_detail(name: str, args: dict) -> str:
    """One-line argument summary, paths shortened to a basename."""
    keys = _TOOL_ARGS.get(name) or tuple(args)[:1]
    for key in keys:
        value = args.get(key)
        if not isinstance(value, str) or not value:
            continue
        if key.endswith("path"):
            value = os.path.basename(value) or value
        return " ".join(value.split())[:80]
    return ""


class ClaudeCodeProcessor(FrameProcessor):
    """Stands where an LLM service normally would.

    Takes final transcriptions in, drives a long-lived Claude Code subprocess,
    and pushes only the speakable prose downstream to TTS. Raw text still goes
    to the notch shell over the bridge.
    """

    def __init__(
        self,
        session: ClaudeCodeSession,
        bridge: NotchBridge,
        cancel_on_interrupt: bool,
        approvals: ApprovalServer | None = None,
    ):
        super().__init__()
        self._session = session
        self._bridge = bridge
        self._approvals = approvals
        self._cancel_on_interrupt = cancel_on_interrupt
        self._filter = SpeechFilter()
        self._consumer: asyncio.Task | None = None
        self._responding = False
        self._dropping = False
        self._pending_turns = 0
        self._raw = ""

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)

        if isinstance(frame, StartFrame):
            await self.push_frame(frame, direction)
            await self._session.start()
            self._consumer = asyncio.create_task(self._consume())
            await self._bridge.state("listening")
            return

        if isinstance(frame, (EndFrame, CancelFrame)):
            if self._consumer:
                self._consumer.cancel()
            await self._session.stop()
            await self.push_frame(frame, direction)
            return

        if isinstance(frame, (InterruptionFrame, UserStartedSpeakingFrame)):
            await self._handle_interruption()
            await self.push_frame(frame, direction)
            return

        if isinstance(frame, TranscriptionFrame) and frame.text.strip():
            if await self._answered_approval(frame.text):
                return
            await self._bridge.send(
                {"type": "transcript", "role": "user", "text": frame.text, "final": True}
            )
            await self._bridge.state("thinking")
            self._filter.reset()
            self._raw = ""
            try:
                self._pending_turns += 1
                await self._session.send_user_text(frame.text)
            except Exception as e:
                self._pending_turns -= 1
                logger.error(f"failed to send turn to claude code: {e}")
                await self._bridge.send({"type": "error", "message": str(e)})
            return

        await self.push_frame(frame, direction)

    async def _answered_approval(self, text: str) -> bool:
        """Consume a spoken yes/no while a permission question is open."""
        if not self._approvals or not self._approvals.pending_id:
            return False
        verdict = hears_approval(text)
        if verdict is None:
            return False
        await self._bridge.send(
            {"type": "transcript", "role": "user", "text": text, "final": True}
        )
        await self.resolve_approval(verdict, "by voice")
        return True

    async def resolve_approval(self, approved: bool, how: str = ""):
        if not self._approvals:
            return
        req_id = self._approvals.pending_id
        if not req_id or not self._approvals.resolve(req_id, approved, how):
            return
        await self._bridge.send({"type": "approval_closed", "id": req_id, "approved": approved})
        await self._bridge.state("thinking")

    async def ask_approval(self, request: dict):
        """A hook is blocked on us; put the question in the notch and say it."""
        await self._bridge.send(
            {
                "type": "approval",
                "id": request["id"],
                "tool": request.get("tool", "tool"),
                "reason": request.get("reason", ""),
            }
        )
        await self._bridge.state("waiting")
        await self._speak_now(f"{request.get('reason', 'This one')} — want me to go ahead?")

    async def _speak_now(self, text: str):
        """Say something that isn't part of Claude's streamed answer."""
        if not self._responding:
            self._responding = True
            await self.push_frame(LLMFullResponseStartFrame())
        await self.push_frame(LLMTextFrame(text))
        await self.push_frame(LLMFullResponseEndFrame())
        self._responding = False

    async def send_text_turn(self, text: str):
        """Typed input from the notch shell — same path as a spoken turn."""
        await self.process_frame(
            TranscriptionFrame(text=text, user_id="shell", timestamp=""),
            FrameDirection.DOWNSTREAM,
        )

    async def _handle_interruption(self):
        if not self._responding and not self._dropping:
            return
        self._dropping = True
        self._filter.reset()
        if self._responding:
            await self.push_frame(LLMFullResponseEndFrame())
            self._responding = False
        if self._cancel_on_interrupt:
            await self._session.interrupt()

    async def _speak(self, text: str):
        # A turn we already talked over may still be streaming; only the newest one speaks.
        if self._dropping or self._pending_turns > 1 or not text:
            return
        if not self._responding:
            self._responding = True
            await self.push_frame(LLMFullResponseStartFrame())
            await self._bridge.state("speaking")
        await self.push_frame(LLMTextFrame(text + " "))

    async def _consume(self):
        async for event in self._session.stream():
            kind = event["kind"]

            if kind == "ready":
                await self._bridge.send(
                    {"type": "session", "id": event["session_id"], "cwd": self._session.cwd}
                )

            elif kind == "turn_start":
                self._raw = ""

            elif kind == "text_delta":
                if self._pending_turns > 1:
                    continue
                self._raw += event["text"]
                await self._bridge.send({"type": "assistant_delta", "text": event["text"]})
                for chunk in self._filter.feed(event["text"]):
                    await self._speak(chunk)

            elif kind == "tool_use":
                name = event["name"]
                verb = _TOOL_NARRATION.get(name, f"using {name}")
                await self._bridge.send(
                    {
                        "type": "tool",
                        "id": event.get("id", ""),
                        "name": name,
                        "summary": verb,
                        "detail": _tool_detail(name, event.get("input") or {}),
                    }
                )

            elif kind == "tool_result":
                await self._bridge.send(
                    {
                        "type": "tool_result",
                        "id": event.get("id", ""),
                        "ok": not event.get("is_error"),
                        "text": event.get("text", ""),
                    }
                )

            elif kind == "turn_end":
                self._pending_turns = max(0, self._pending_turns - 1)
                self._dropping = False
                if self._pending_turns > 0:
                    continue
                for chunk in self._filter.flush():
                    await self._speak(chunk)
                if self._responding:
                    await self.push_frame(LLMFullResponseEndFrame())
                    self._responding = False
                await self._bridge.send({"type": "assistant_done", "text": self._raw})
                await self._bridge.state("listening")
                if event.get("is_error"):
                    await self._bridge.send({"type": "error", "message": event.get("text", "")})

            elif kind == "process_exit":
                logger.error("claude code process exited")
                await self._bridge.send({"type": "error", "message": "claude code exited"})
                await self._bridge.state("error")
                break
