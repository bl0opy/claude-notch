import time

from loguru import logger
from pipecat.frames.frames import (
    BotStartedSpeakingFrame,
    BotStoppedSpeakingFrame,
    Frame,
    InputAudioRawFrame,
)
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor


class MicGate(FrameProcessor):
    """Half-duplex gate: drops mic audio while the agent is talking.

    The built-in mic hears the built-in speakers (measured at ~3.5x room noise
    at moderate volume), and there is no echo canceller in this pipeline. Left
    open, Flux transcribes the agent's own voice, fires an interrupt, and Claude
    Code answers the interruption — which plays more audio and starts the loop
    again. Gating the mic for the duration of the reply plus a short tail breaks
    it. Barge-in by voice goes away; Option-Space and the stop button still work.

    Set MIC_GATE=0 if you're on headphones and want voice barge-in back.
    """

    def __init__(self, tail_ms: int = 250):
        super().__init__()
        self._tail = tail_ms / 1000
        self._speaking = False
        self._open_at = 0.0
        self._dropped = 0

    @property
    def _closed(self) -> bool:
        return self._speaking or time.monotonic() < self._open_at

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)

        if isinstance(frame, BotStartedSpeakingFrame):
            self._speaking = True
            self._dropped = 0
        elif isinstance(frame, BotStoppedSpeakingFrame):
            self._speaking = False
            self._open_at = time.monotonic() + self._tail
            if self._dropped:
                logger.debug(f"mic gate: dropped {self._dropped} frames while speaking")

        if isinstance(frame, InputAudioRawFrame) and self._closed:
            self._dropped += 1
            return

        await self.push_frame(frame, direction)
