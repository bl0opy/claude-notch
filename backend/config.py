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
    eot_threshold: float = field(default_factory=lambda: float(os.getenv("EOT_THRESHOLD", "0.7")))
    eot_timeout_ms: int = field(default_factory=lambda: int(os.getenv("EOT_TIMEOUT_MS", "3000")))
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
