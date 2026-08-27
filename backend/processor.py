import asyncio

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


class ClaudeCodeProcessor(FrameProcessor):
    """Stands where an LLM service normally would.

    Takes final transcriptions in, drives a long-lived Claude Code subprocess,
    and pushes only the speakable prose downstream to TTS. Raw text still goes
    to the notch shell over the bridge.
    """

    def __init__(self, session: ClaudeCodeSession, bridge: NotchBridge, cancel_on_interrupt: bool):
        super().__init__()
        self._session = session
        self._bridge = bridge
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
                verb = _TOOL_NARRATION.get(event["name"], f"using {event['name']}")
                await self._bridge.send(
                    {"type": "tool", "name": event["name"], "summary": verb}
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
