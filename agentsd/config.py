import os
from dataclasses import dataclass, field


@dataclass
class Config:
    ws_host: str = field(default_factory=lambda: os.getenv("AGENTS_WS_HOST", "127.0.0.1"))
    ws_port: int = field(default_factory=lambda: int(os.getenv("AGENTS_WS_PORT", "8767")))
    inbox_port: int = field(default_factory=lambda: int(os.getenv("NOTCH_INBOX_PORT", "8766")))
    # An owned agent's question with nobody answering is a deny after this. A
    # terminal one just stops showing in the notch; its own dialog is still up.
    owned_timeout_s: float = field(default_factory=lambda: float(os.getenv("APPROVAL_TIMEOUT_S", "180")))
    terminal_timeout_s: float = field(default_factory=lambda: float(os.getenv("NOTCH_TERMINAL_WAIT_S", "590")))
    tick_s: float = field(default_factory=lambda: float(os.getenv("AGENTS_TICK_S", "1.0")))
    # Prompt text and tool arguments cross a loopback socket to the notch. Off
    # for anyone who would rather they didn't.
    send_details: bool = field(default_factory=lambda: os.getenv("AGENTS_SEND_DETAILS", "1") == "1")


config = Config()
