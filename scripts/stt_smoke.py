"""Proves the local STT path: 48 kHz mic audio in, corrected text out, no key.

    .venv/bin/python scripts/stt_smoke.py

Synthesises its own speech with `say`, so it needs no microphone and no
recording. That also means the accuracy here is on a synthetic voice — it says
whether the path works and how fast, not how well it hears you.
"""
import asyncio
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipecat.frames.frames import TranscriptionFrame

from backend.stt import ParakeetSTTService
from backend.vocab import Vocabulary

RATE = 48000
LINES = [
    "approve orbit",
    "what's waiting",
    "go to descant and check the websocket port",
    "stop the agent in bus tracker and tell me if the tests pass",
]


class FixedVocabulary(Vocabulary):
    """The real one reads the live roster; this one is the repos in the workspace."""

    def __init__(self, names):
        super().__init__()
        self._fixed = names

    def names(self):
        return self._fixed


def say(text: str, path: Path) -> bytes:
    aiff = path.with_suffix(".aiff")
    subprocess.run(["say", "-v", "Samantha", "-r", "180", "-o", str(aiff), text], check=True)
    subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", str(aiff), str(path)],
        check=True, capture_output=True,
    )
    with wave.open(str(path)) as w:
        return w.readframes(w.getnframes())


async def main():
    names = ["orbit", "descant-ide", "bus-tracker", "voice-agent", "wound-stage"]
    stt = ParakeetSTTService(
        model="mlx-community/parakeet-tdt-0.6b-v3",
        vocabulary=FixedVocabulary(names),
        sample_rate=RATE,
    )
    # In the app this is set when the pipeline sets the service up; here
    # there's no pipeline, so say what rate the audio arrives at.
    stt._sample_rate = RATE
    t = time.perf_counter()
    await asyncio.to_thread(stt._load)
    print(f"model load: {time.perf_counter() - t:.1f}s\n")

    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        for i, line in enumerate(LINES):
            pcm = say(line, Path(tmp) / f"{i}.wav")
            seconds = len(pcm) / (RATE * 2)
            t = time.perf_counter()
            frames = [f async for f in stt.run_stt(pcm) if isinstance(f, TranscriptionFrame)]
            took = time.perf_counter() - t
            got = frames[0].text if frames else ""
            print(f"  said  {line}")
            print(f"  heard {got}")
            print(f"        {seconds:.1f}s audio, {took * 1000:.0f} ms from key-up\n")
            if not got:
                failures.append(line)

    # The names are what the spoken commands address, so those must survive —
    # and a phrase that merely sits near a name must be left alone, or the
    # repair becomes its own source of wrong turns.
    v = FixedVocabulary(names)
    repairs = [
        ("go to desk and then check the port", "descant-ide"),
        ("approve orbits", "orbit"),
        ("stop the agent in bus trucker", "bus-tracker"),
    ]
    leave_alone = [
        "what's waiting",
        "stop the agent and tell me if the tests pass",
        "check the port it's listening on",
        "that one wants to push to git",
    ]
    for heard, want in repairs:
        fixed = v.correct(heard)
        ok = want in fixed
        print(f"{'ok  ' if ok else 'FAIL'} repairs: {heard!r} -> {fixed!r}")
        if not ok:
            failures.append(heard)
    for heard in leave_alone:
        fixed = v.correct(heard)
        ok = fixed == heard
        print(f"{'ok  ' if ok else 'FAIL'} leaves:  {heard!r}" + ("" if ok else f" -> {fixed!r}"))
        if not ok:
            failures.append(heard)

    print()
    if failures:
        print(f"{len(failures)} failed")
        return 1
    print("all good")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
