# voice-agent

Voice-native Claude Code, living in the MacBook notch. Talk through code out loud;
Claude Code does the actual work underneath.

```
SwiftUI notch shell  ◄── ws://127.0.0.1:8765 ──►  Python backend
  state / transcript                                Deepgram Flux (STT)
  stop button, ⌥Space                               claude -p (stream-json)
                                                    Deepgram Aura-2 (TTS)
```

## Setup

```bash
pyenv local 3.11.6 && python -m venv .venv
.venv/bin/pip install "pipecat-ai[deepgram,local,silero,webrtc]" websockets python-dotenv
cp .env.example .env      # fill in DEEPGRAM_API_KEY
```

`claude` must be on PATH and already logged in.

## Run

```bash
./run.sh                       # backend + shell
.venv/bin/python -m backend.main   # backend only
```

Hover the notch to expand. `stop` (or ⌥Space anywhere) interrupts.

## Layout

| Path | What |
|---|---|
| `backend/main.py` | Pipecat pipeline wiring |
| `backend/claude_code.py` | Long-lived `claude -p` subprocess, stream-json in/out |
| `backend/processor.py` | Sits where an LLM service would; drives Claude Code, feeds TTS |
| `backend/speech.py` | Strips code blocks/diffs/markdown before anything is spoken |
| `backend/bridge.py` | WebSocket server the notch shell talks to |
| `shell/NotchAgent/` | SwiftUI app (SPM executable) |
| `scripts/mock_bridge.py` | Fake backend for developing the shell without API keys |

## WebSocket protocol

Backend → shell:

```json
{"type": "state",           "value": "idle|listening|thinking|speaking|error"}
{"type": "transcript",      "role": "user", "text": "...", "final": true}
{"type": "assistant_delta", "text": "..."}
{"type": "assistant_done",  "text": "<full raw turn>"}
{"type": "tool",            "name": "Edit", "summary": "editing"}
{"type": "session",         "id": "...", "cwd": "..."}
{"type": "error",           "message": "..."}
```

Shell → backend:

```json
{"type": "interrupt"}
{"type": "text", "text": "typed turn, same path as a spoken one"}
{"type": "say",  "text": "speak this verbatim"}
```

## Config

All via `.env`: `DEEPGRAM_MODEL`, `DEEPGRAM_VOICE`, `EOT_THRESHOLD`, `EOT_TIMEOUT_MS`,
`CLAUDE_CWD`, `CLAUDE_MODEL`, `CLAUDE_PERMISSION_MODE`, `CANCEL_ON_INTERRUPT`,
`WS_HOST`, `WS_PORT`.

STT and TTS share one Deepgram key — no second vendor.
