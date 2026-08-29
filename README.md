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

`claude` must be on PATH and already logged in. It runs on Sonnet 5 — override
with `CLAUDE_MODEL`, or set it empty to use the CLI's own default.

## Run

```bash
./run.sh                       # backend + shell
.venv/bin/python -m backend.main   # backend only
```

Hold **right ⌥** to talk, let go when you're done — the mic is shut the rest of
the time. It's a global monitor, so it works in whatever app is frontmost, and
nothing binds right ⌥ on its own, so it never doubles as a shortcut. Holding it
while Claude is talking cuts it off. Needs Accessibility permission. Set
`PUSH_TO_TALK=0` for the old always-on mic.

Pick a different key with `PTT_KEY` (env, or `PTTKey` in defaults):
`rightOption` (default), `rightCommand`, `fn`, `leftOption`, `command`. `command`
is the old behaviour — it has to be held alone for 200 ms and any other key
cancels it, since ⌘ is half of every shortcut on the machine.

It speaks at most two sentences per turn (`SPOKEN_SENTENCES`) — the notch still
shows the full answer. Permission questions are spoken as
"I need your approval for deleting some files"; the actual command stays on screen.

Hover the notch to expand. `stop` (or ⌥Space anywhere) interrupts.

## Layout

| Path | What |
|---|---|
| `backend/main.py` | Pipecat pipeline wiring |
| `backend/claude_code.py` | Long-lived `claude -p` subprocess, stream-json in/out |
| `backend/processor.py` | Sits where an LLM service would; drives Claude Code, feeds TTS |
| `backend/speech.py` | Strips code blocks/diffs/markdown before anything is spoken |
| `backend/ptt.py` | Push-to-talk gate — silences the mic unless the key is held |
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

### Approvals

`CLAUDE_PERMISSION_MODE` defaults to `auto`. A `PreToolUse` hook (`hooks/approve.py`)
gates the risky minority — `rm -rf`, `sudo`, `git push`/`reset --hard`, package
installs, writes outside the project, `WebFetch` — and lets everything else through
so auto mode stays quiet. When it fires, the agent asks out loud and the notch shows
Approve/Deny; saying "yeah" or "nope" answers it, and so does the button.
`APPROVAL_TIMEOUT_S` (default 180) denies on silence so a turn can't wedge.

Edit `RISKY_BASH` and `risk()` in `hooks/approve.py` to change what gets gated.

One limit worth knowing: the hook can *veto* a tool call, but a hook `allow`
does not override Claude Code's own refusals. Verified against the CLI: approving
a call the CLI already permits runs it, and denying blocks it — but approving
something the CLI itself refuses in headless mode (`rm -rf`, for one) still won't
run it, in any permission mode. Claude Code keeps the final say.

### Audio

`AUDIO_IN_DEVICE` / `AUDIO_OUT_DEVICE` take a device name substring or a pyaudio
index. Left empty they pin the MacBook built-in mic and speakers by name, so a
connected interface never gets picked up just because it is the system default.

`AUDIO_SAMPLE_RATE` (default 48000) drives the mic, the speakers and the pipeline
as one rate. The built-in devices are natively 48 kHz, so nothing resamples at the
device layer. The backend logs each device's native rate at startup and warns if
it disagrees with the one you asked for.

`MIC_GATE` (default 1) holds the mic shut while the agent talks, plus
`MIC_GATE_TAIL_MS` (default 250) for the room to settle. The built-in mic hears
the built-in speakers — measured at 3.5x room noise at moderate volume — and
there is no echo canceller here, so an open mic makes Flux transcribe the
agent's own voice, fire an interrupt, and set Claude Code answering itself in a
loop. The cost is that voice barge-in stops working; Option-Space and the stop
button still interrupt. Set `MIC_GATE=0` on headphones to get barge-in back.

`TTS_SAMPLE_RATE` (default 24000) is the one deliberate exception: aura-2 is a
24 kHz model, so 24 -> 48 kHz has to happen somewhere. Measured on one utterance,
asking Deepgram for 48 kHz leaves 0.17% of total energy above 12 kHz — imaging
junk above the model's own Nyquist, which is what reads as harsh. Rendering
native and resampling locally through pipecat's soxr VHQ leaves 0.00000% up
there, so that is the default.

STT and TTS share one Deepgram key — no second vendor.
