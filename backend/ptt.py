from loguru import logger
from pipecat.frames.frames import Frame, InputAudioRawFrame
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor


class PushToTalkGate(FrameProcessor):
    """Mic is shut until the shell says the key is held.

    Closed frames are replaced with silence rather than dropped: Flux measures
    end-of-turn from the audio it receives, so a stream that simply stops never
    fires one and the last utterance hangs. Feeding silence keeps its clock
    running, and letting go of the key reads as the end of the turn.
    """

    def __init__(self):
        super().__init__()
        self._open = False

    @property
    def is_open(self) -> bool:
        return self._open

    def set_open(self, value: bool):
        if value == self._open:
            return
        self._open = value
        logger.debug(f"push-to-talk: mic {'open' if value else 'closed'}")

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)

        if isinstance(frame, InputAudioRawFrame) and not self._open:
            frame = InputAudioRawFrame(
                audio=bytes(len(frame.audio)),
                sample_rate=frame.sample_rate,
                num_channels=frame.num_channels,
            )

        await self.push_frame(frame, direction)
