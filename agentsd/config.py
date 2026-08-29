import os
from dataclasses import dataclass, field


@dataclass
class Config:
    ws_host: str = field(default_factory=lambda: os.getenv("AGENTS_WS_HOST", "127.0.0.1"))
    ws_port: int = field(default_factory=lambda: int(os.getenv("AGENTS_WS_PORT", "8767")))
    tick_s: float = field(default_factory=lambda: float(os.getenv("AGENTS_TICK_S", "1.0")))
    # Prompt text and tool arguments cross a loopback socket to the notch. Off
    # for anyone who would rather they didn't.
    send_details: bool = field(default_factory=lambda: os.getenv("AGENTS_SEND_DETAILS", "1") == "1")


config = Config()
