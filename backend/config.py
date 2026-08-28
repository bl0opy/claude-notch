import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")


@dataclass
class Config:
    deepgram_api_key: str = field(default_factory=lambda: os.getenv("DEEPGRAM_API_KEY", ""))
    deepgram_model: str = field(default_factory=lambda: os.getenv("DEEPGRAM_MODEL", "flux-general-en"))
    deepgram_voice: str = field(
        default_factory=lambda: os.getenv("DEEPGRAM_VOICE", "aura-2-thalia-en")
    )
    audio_in_sample_rate: int = field(
        default_factory=lambda: int(os.getenv("AUDIO_IN_SAMPLE_RATE", "16000"))
    )
    audio_out_sample_rate: int = field(
        default_factory=lambda: int(os.getenv("AUDIO_OUT_SAMPLE_RATE", "48000"))
    )
    # aura-2 renders at 24 kHz; asking Deepgram for a higher rate returns a
    # poorly upsampled stream with audible imaging. Synthesize native, let
    # pipecat resample to the device rate with soxr.
    tts_sample_rate: int = field(
        default_factory=lambda: int(os.getenv("TTS_SAMPLE_RATE", "24000"))
    )
    input_device_index: int | None = field(
        default_factory=lambda: int(os.environ["AUDIO_IN_DEVICE"])
        if os.getenv("AUDIO_IN_DEVICE")
        else None
    )
    output_device_index: int | None = field(
        default_factory=lambda: int(os.environ["AUDIO_OUT_DEVICE"])
        if os.getenv("AUDIO_OUT_DEVICE")
        else None
    )
    eot_threshold: float = field(default_factory=lambda: float(os.getenv("EOT_THRESHOLD", "0.7")))
    eot_timeout_ms: int = field(default_factory=lambda: int(os.getenv("EOT_TIMEOUT_MS", "1500")))
    ws_host: str = field(default_factory=lambda: os.getenv("WS_HOST", "127.0.0.1"))
    ws_port: int = field(default_factory=lambda: int(os.getenv("WS_PORT", "8765")))
    claude_cwd: str = field(default_factory=lambda: os.getenv("CLAUDE_CWD", str(Path.cwd())))
    claude_model: str = field(default_factory=lambda: os.getenv("CLAUDE_MODEL", ""))
    permission_mode: str = field(default_factory=lambda: os.getenv("CLAUDE_PERMISSION_MODE", "acceptEdits"))
    cancel_on_interrupt: bool = field(
        default_factory=lambda: os.getenv("CANCEL_ON_INTERRUPT", "1") == "1"
    )

    def missing_keys(self) -> list[str]:
        return [] if self.deepgram_api_key else ["DEEPGRAM_API_KEY"]


config = Config()
