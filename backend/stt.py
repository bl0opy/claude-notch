"""Speech to text, cloud or on-device.

Deepgram Flux is the better transcriber and stays the default. The local path
exists so the app can be installed and used with no API key at all, which is
most of what stands between this and being handed to someone else.

Push-to-talk is what makes a local model viable here. Flux earns its keep by
deciding *when* a turn ended from the audio itself; with hold-to-talk the key
already says so, so the local model never has to do the hard part — it gets a
bounded buffer on key release and has one job, transcribe it. Measured on an
M1 Max, parakeet-tdt-0.6b-v3: 49 ms for a two-word command, 90 ms for a
five-second sentence, against a 1.6 s one-time load at startup.
"""
import asyncio
from concurrent.futures import ThreadPoolExecutor
from typing import AsyncGenerator

import numpy as np
from loguru import logger
from pipecat.audio.resamplers.soxr_resampler import SOXRAudioResampler
from pipecat.frames.frames import ErrorFrame, Frame, TranscriptionFrame
from pipecat.services.stt_service import SegmentedSTTService
from pipecat.utils.time import time_now_iso8601

# What the model's own front end expects; unrelated to the pipeline's rate.
MODEL_RATE = 16000


class ParakeetSTTService(SegmentedSTTService):
    """On-device STT. Segments come from the push-to-talk key, not from a VAD."""

    def __init__(self, *, model: str, vocabulary=None, **kwargs):
        super().__init__(**kwargs)
        self._model_name = model
        self._model = None
        self._resampler = SOXRAudioResampler()
        self._vocabulary = vocabulary
        # MLX streams belong to the thread that created them: a model loaded on
        # one thread fails on any other with "There is no Stream(cpu, 1) in
        # current thread". asyncio.to_thread hands out whichever pool worker is
        # free, so everything MLX touches runs on this one thread instead.
        self._mlx = ThreadPoolExecutor(max_workers=1, thread_name_prefix="parakeet")

    @property
    def wants_wav_segments(self) -> bool:
        # The model reads raw PCM; a WAV header would be transcribed as audio.
        return False

    def can_generate_metrics(self) -> bool:
        return True

    async def start(self, frame):
        await super().start(frame)
        # ~1.6 s off the main thread, so the notch comes up while it loads.
        await self._on_mlx(self._load)

    async def _on_mlx(self, fn, *args):
        return await asyncio.get_running_loop().run_in_executor(self._mlx, fn, *args)

    def _load(self):
        from parakeet_mlx import from_pretrained

        logger.info(f"loading {self._model_name} — first run downloads it")
        self._model = from_pretrained(self._model_name)
        logger.info("local stt ready")

    async def run_stt(self, audio: bytes) -> AsyncGenerator[Frame, None]:
        if self._model is None:
            yield ErrorFrame("local stt is still loading")
            return
        pcm = await self._resampler.resample(audio, self.sample_rate, MODEL_RATE)
        await self.start_ttfb_metrics()
        try:
            text = await self._on_mlx(self._transcribe_pcm, pcm)
        except Exception as e:
            logger.error(f"local stt failed: {e}")
            yield ErrorFrame(f"local stt failed: {e}")
            return
        await self.stop_ttfb_metrics()
        if not text:
            return
        if self._vocabulary:
            text = self._vocabulary.correct(text)
        logger.debug(f"local stt: {text}")
        yield TranscriptionFrame(text, "", time_now_iso8601())

    def _transcribe_pcm(self, pcm: bytes) -> str:
        import mlx.core as mx
        from parakeet_mlx.audio import get_logmel

        samples = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
        if samples.size == 0:
            return ""
        mel = get_logmel(mx.array(samples), self._model.preprocessor_config)
        result = self._model.generate(mel)
        if isinstance(result, list):
            result = result[0] if result else None
        return (result.text if result else "").strip()
