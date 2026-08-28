import pyaudio
from loguru import logger

# The built-in mac hardware. Pinning by name keeps the agent off whatever
# interface happens to be the system default (a Scarlett, BlackHole, an
# aggregate device) and off its clock.
BUILTIN_INPUT = "MacBook Pro Microphone"
BUILTIN_OUTPUT = "MacBook Pro Speakers"


def _devices(pa: pyaudio.PyAudio) -> list[dict]:
    return [pa.get_device_info_by_index(i) for i in range(pa.get_device_count())]


def resolve_device(spec: str | None, want_input: bool) -> tuple[int | None, str, int]:
    """Return (index, name, native_sample_rate) for a device spec.

    spec may be a pyaudio index, a case-insensitive name substring, or None to
    fall back to the built-in mac device.
    """
    kind = "input" if want_input else "output"
    channels_key = "maxInputChannels" if want_input else "maxOutputChannels"
    pa = pyaudio.PyAudio()
    try:
        devices = _devices(pa)
        usable = [d for d in devices if d[channels_key] > 0]

        if spec and spec.isdigit():
            info = pa.get_device_info_by_index(int(spec))
        else:
            wanted = (spec or (BUILTIN_INPUT if want_input else BUILTIN_OUTPUT)).lower()
            matches = [d for d in usable if wanted in str(d["name"]).lower()]
            if not matches:
                names = ", ".join(str(d["name"]) for d in usable)
                logger.warning(f"no {kind} device matching {wanted!r} — using system default. saw: {names}")
                return None, "system default", 0
            info = matches[0]

        return int(info["index"]), str(info["name"]), int(info["defaultSampleRate"])
    finally:
        pa.terminate()
