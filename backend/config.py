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
    # One rate for the whole path. The built-in mac mic and speakers are both
    # natively 48 kHz, and matching it end to end means nothing resamples:
    # not CoreAudio at the device, not pipecat between TTS and output.
    audio_sample_rate: int = field(
        default_factory=lambda: int(os.getenv("AUDIO_SAMPLE_RATE", "48000"))
    )
    # aura-2 is a 24 kHz model, so the 24 -> 48 kHz step is unavoidable; the only
    # choice is who does it. Measured on the same utterance: asking Deepgram for
    # 48 kHz puts 0.17% of total energy above 12 kHz, i.e. imaging junk above the
    # model's own Nyquist, which is what reads as harsh and distorted. Rendering
    # native and letting pipecat's soxr VHQ do it leaves 0.00000% up there.
    tts_sample_rate: int = field(
        default_factory=lambda: int(os.getenv("TTS_SAMPLE_RATE", "24000"))
    )
    # Name substring or pyaudio index. Empty pins the MacBook built-in devices,
    # ignoring whatever interface is the current system default.
    input_device: str = field(default_factory=lambda: os.getenv("AUDIO_IN_DEVICE", ""))
    output_device: str = field(default_factory=lambda: os.getenv("AUDIO_OUT_DEVICE", ""))
    # Hold-to-talk: the mic is shut unless the notch shell says the key is down.
    # With it on the mic gate is redundant — nothing gets in while Claude talks
    # unless you deliberately hold the key to barge in.
    push_to_talk: bool = field(default_factory=lambda: os.getenv("PUSH_TO_TALK", "1") == "1")
    # A held key is one turn, no matter how many pauses it contains. The last
    # words still arrive after the key is up, so the turn is sealed this long
    # after the release rather than the instant it happens.
    ptt_tail_ms: int = field(default_factory=lambda: int(os.getenv("PTT_TAIL_MS", "400")))
    # The built-in mic hears the built-in speakers and there's no echo canceller,
    # so hold the mic shut while the agent talks. Turn off on headphones.
    mic_gate: bool = field(default_factory=lambda: os.getenv("MIC_GATE", "1") == "1")
    mic_gate_tail_ms: int = field(
        default_factory=lambda: int(os.getenv("MIC_GATE_TAIL_MS", "250"))
    )
    # How many sentences of a turn ever reach the speakers. The notch prints
    # everything regardless.
    spoken_sentences: int = field(
        default_factory=lambda: int(os.getenv("SPOKEN_SENTENCES", "2"))
    )
    eot_threshold: float = field(default_factory=lambda: float(os.getenv("EOT_THRESHOLD", "0.7")))
    eot_timeout_ms: int = field(default_factory=lambda: int(os.getenv("EOT_TIMEOUT_MS", "1500")))
    ws_host: str = field(default_factory=lambda: os.getenv("WS_HOST", "127.0.0.1"))
    ws_port: int = field(default_factory=lambda: int(os.getenv("WS_PORT", "8765")))
    claude_cwd: str = field(default_factory=lambda: os.getenv("CLAUDE_CWD", str(Path.cwd())))
    # Sonnet by default: the notch agent is short-turn conversational work, and
    # the CLI's own default (Opus) is more model than that needs. Empty falls
    # back to whatever `claude` is configured to use.
    claude_model: str = field(
        default_factory=lambda: os.getenv("CLAUDE_MODEL", "claude-sonnet-5")
    )
    permission_mode: str = field(default_factory=lambda: os.getenv("CLAUDE_PERMISSION_MODE", "auto"))
    approval_timeout_s: float = field(
        default_factory=lambda: float(os.getenv("APPROVAL_TIMEOUT_S", "180"))
    )
    cancel_on_interrupt: bool = field(
        default_factory=lambda: os.getenv("CANCEL_ON_INTERRUPT", "1") == "1"
    )

    def missing_keys(self) -> list[str]:
        return [] if self.deepgram_api_key else ["DEEPGRAM_API_KEY"]


config = Config()
