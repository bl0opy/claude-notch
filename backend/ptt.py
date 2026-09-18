from loguru import logger
from pipecat.frames.frames import (
    Frame,
    InputAudioRawFrame,
    VADUserStartedSpeakingFrame,
    VADUserStoppedSpeakingFrame,
)
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor


class PushToTalkGate(FrameProcessor):
    """Mic is shut until the shell says the key is held.

    Closed frames are replaced with silence rather than dropped: Flux measures
    end-of-turn from the audio it receives, so a stream that simply stops never
    fires one and the last utterance hangs. Feeding silence keeps its clock
    running, and letting go of the key reads as the end of the turn.
    """

    def __init__(self, announce_speech: bool = False):
        super().__init__()
        self._open = False
        # A segmented STT cuts turns on VAD frames. With hold-to-talk the key
        # already knows where a turn starts and ends, better than a VAD does,
        # so it emits them itself. Flux does its own end-of-turn detection and
        # would only be confused by them, hence the flag.
        self._announce = announce_speech
        self._pending: list[Frame] = []

    @property
    def is_open(self) -> bool:
        return self._open

    def set_open(self, value: bool):
        if value == self._open:
            return
        self._open = value
        logger.debug(f"push-to-talk: mic {'open' if value else 'closed'}")
        if self._announce:
            # Queued rather than pushed: this is called from the bridge's task,
            # and frames have to enter the pipeline in order with the audio.
            self._pending.append(
                VADUserStartedSpeakingFrame() if value else VADUserStoppedSpeakingFrame()
            )

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)

        while self._pending:
            await self.push_frame(self._pending.pop(0), FrameDirection.DOWNSTREAM)

        if isinstance(frame, InputAudioRawFrame) and not self._open:
            frame = InputAudioRawFrame(
                audio=bytes(len(frame.audio)),
                sample_rate=frame.sample_rate,
                num_channels=frame.num_channels,
            )

        await self.push_frame(frame, direction)
