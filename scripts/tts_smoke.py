"""Proves the local TTS path: text in, 24 kHz audio out, no key.

    .venv/bin/python scripts/tts_smoke.py [out.wav]

Goes through backend.main.build_tts, so it tests what the app builds. Pass a
path to write what was spoken, to listen to it.
"""
import asyncio
import sys
import time
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np
from pipecat.frames.frames import ErrorFrame, TTSAudioRawFrame

from backend import main
from backend.config import config

# What the notch actually says: a sentence at a time, already stripped of code.
LINES = [
    "Done.",
    "Orbit wants to push to git.",
    "The tests pass, and the tail fix is in.",
    "The notch should reconnect on its own within a few seconds.",
]
# The first sentence of a reply is what you wait for; later ones render while
# earlier ones play. A second is the most that still feels like a reply.
FIRST_AUDIO_BUDGET_S = 1.0


async def run() -> int:
    config.tts_backend = "kokoro"
    config.deepgram_api_key = ""
    main.resolve_backends()
    failures = []
    if config.missing_keys():
        failures.append(f"fully local still asks for {config.missing_keys()}")

    t = time.perf_counter()
    tts = main.build_tts()
    print(f"built {type(tts).__name__} in {time.perf_counter() - t:.1f}s")
    # In the app the pipeline sets this when it sets the service up.
    tts._sample_rate = config.tts_sample_rate

    spoken = []
    async def say(text: str):
        t = time.perf_counter(); first = None; pcm = b""
        async for frame in tts.run_tts(text, "smoke"):
            if isinstance(frame, ErrorFrame):
                raise RuntimeError(frame.error)
            if isinstance(frame, TTSAudioRawFrame):
                first = first or time.perf_counter() - t
                if frame.sample_rate != config.tts_sample_rate:
                    failures.append(f"{frame.sample_rate} Hz, wanted {config.tts_sample_rate}")
                pcm += frame.audio
        return first, pcm

    await say("warm up")
    print()
    for line in LINES:
        first, pcm = await say(line)
        samples = np.frombuffer(pcm, dtype=np.int16)
        seconds = samples.size / config.tts_sample_rate
        loud = float(np.sqrt(np.mean(samples.astype(np.float64) ** 2))) if samples.size else 0.0
        ok = first is not None and first <= FIRST_AUDIO_BUDGET_S and loud > 300
        print(f"{'ok  ' if ok else 'FAIL'} {first * 1000 if first else 0:5.0f} ms to first audio, "
              f"{seconds:.1f}s, rms {loud:5.0f}  {line}")
        if not ok:
            failures.append(line)
        spoken.append(samples)

    if len(sys.argv) > 1:
        gap = np.zeros(int(0.3 * config.tts_sample_rate), dtype=np.int16)
        with wave.open(sys.argv[1], "wb") as out:
            out.setnchannels(1); out.setsampwidth(2); out.setframerate(config.tts_sample_rate)
            out.writeframes(b"".join(np.concatenate([s, gap]).tobytes() for s in spoken))
        print(f"\nwrote {sys.argv[1]}")

    print()
    if failures:
        print(f"{len(failures)} failed: {failures}")
        return 1
    print("all good")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(run()))
