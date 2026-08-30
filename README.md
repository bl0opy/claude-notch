# voice-agent

Voice-native Claude Code, living in the MacBook notch. Talk through code out loud;
Claude Code does the actual work underneath.

```
SwiftUI notch shell  ◄── ws://127.0.0.1:8765 ──►  Python backend
  state / transcript / tools                        Deepgram Flux (STT)
  hold right ⌥ to talk                              claude -p (stream-json)
  stop button, ⌥Space                               Deepgram Aura-2 (TTS)
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

**The key ends the turn, not the silence.** Flux calls end-of-turn on every
pause, so thinking mid-sentence used to send half a question. While the key is
down those pieces are collected and the notch shows them building up; the turn
is sent when you let go, plus `PTT_TAIL_MS` (400) for the words that arrive
after the key is already up.

Talking again while it's still working **steers** it, the way typing at Claude
Code mid-turn does: the in-flight turn is interrupted and the new one goes in
its place. Nothing waits for a turn to finish first. A session running in a
terminal can't be steered — it has no input we can cut into — so words for a
busy one are held and delivered when it frees up, and given up on after two
minutes rather than held forever.

Pick a different key with `PTT_KEY` (env, or `PTTKey` in defaults):
`rightOption` (default), `rightCommand`, `fn`, `leftOption`, `command`. `command`
is the old behaviour — it has to be held alone for 200 ms and any other key
cancels it, since ⌘ is half of every shortcut on the machine.

It speaks at most two sentences per turn (`SPOKEN_SENTENCES`) — the notch still
shows the full answer, and `backend/speech.py` strips code, diffs and markdown
out of whatever does get spoken. Permission questions are spoken as
"I need your approval for deleting some files"; the actual command stays on screen.

Hover the notch to expand, click it to pin it open. `stop` (or ⌥Space anywhere)
interrupts.

## Every agent, in the notch

The expanded panel has two tabs. **focus** is the agent you're talking to — what
you said, what it said, what it's doing. **agents** is the dashboard: every
Claude Code session on the machine, project, branch, what it's doing, tokens
spent, worst state first, so an agent blocked on a permission prompt sits at the
top. Click a row to focus it: the focused agent is the one that hears the mic and
the only one that speaks. Everything else works silently and gets a one-line
interjection when it blocks or finishes. The dashboard is also on the menu bar
item, and the count beside the status dot opens it.

**+ agent** on the dashboard (or *New agent…* in the menu) picks a repo and
starts an agent there, owned by the notch — which is what makes it steerable and
its permission prompts answerable by voice. The status dot count and the roster
come from the agents daemon; if it isn't running the dashboard says so instead of
showing nothing.

```bash
.venv/bin/python -m agentsd --once   # print one snapshot and exit
scripts/install-agentsd.sh           # run it at login (launchd, port 8767)
```

Agents come in two kinds, and the notch is explicit about which is which:

| | started by the notch | started in a terminal |
|---|---|---|
| listed, with live state and tokens | yes | yes |
| focus, talk to it, hear it back | yes | yes |
| interrupt | yes | no — `stop` reads `can't stop` |
| approve or deny by voice | yes | no — announced, answered in its terminal |

Talking to a terminal session goes over the peer socket Claude Code already
serves (`/tmp/cc-socks/<pid>.sock`, authenticated with that session's own key
file) and its answer is read back from its transcript. If it's mid-turn the words
are held and delivered the moment it's free, so nothing lands as a dialog in a
window you aren't looking at. Answering *its* permission prompts isn't possible
from outside — that's a Claude Code limit, not a missing feature — which is why
the notch can start agents of its own.

Both are undocumented surfaces (`~/.claude/sessions/` and the peer socket),
verified against 2.1.251. When either changes, rows degrade to `unknown` and the
roster keeps working rather than the daemon crashing.

## Layout

| Path | What |
|---|---|
| `backend/main.py` | Pipecat pipeline wiring |
| `backend/claude_code.py` | Long-lived `claude -p` subprocess, stream-json in/out |
| `backend/processor.py` | Sits where an LLM service would; drives Claude Code, feeds TTS |
| `backend/speech.py` | Strips code blocks/diffs/markdown before anything is spoken |
| `backend/ptt.py` | Push-to-talk gate — silences the mic unless the key is held |
| `backend/agents.py` | Who has focus; routes a spoken turn to the right agent |
| `agentsd/` | Watches every session, serves the roster, talks to foreign ones |
| `backend/bridge.py` | WebSocket server the notch shell talks to |
| `backend/approvals.py` | Holds a blocked hook until the answer comes back |
| `hooks/approve.py` | `PreToolUse` hook — decides what needs asking about |
| `shell/NotchAgent/` | SwiftUI app (SPM executable) |
| `shell/.../PushToTalk.swift` | Global key watcher — right ⌥ opens the mic |
| `shell/.../ProjectPicker.swift` | Directory picker behind `+ agent` |
| `scripts/mock_bridge.py` | Fake backend for developing the shell without API keys |
| `scripts/mock_agents.py` | Fake roster on :8767, for building the agents list |
| `scripts/peer_smoke.py` | Proves a foreign session can be messaged and heard |
| `scripts/director_smoke.py` | Proves focus routing, owned and foreign, no audio |

## WebSocket protocol

Backend → shell:

```json
{"type": "state",           "value": "idle|listening|thinking|speaking|error"}
{"type": "transcript",      "role": "user", "text": "...", "final": true}
{"type": "assistant_delta", "text": "..."}
{"type": "assistant_done",  "text": "<full raw turn>"}
{"type": "tool",            "id": "...", "name": "Edit", "summary": "editing", "detail": "..."}
{"type": "tool_result",     "id": "...", "ok": true, "text": "..."}
{"type": "approval",        "id": "...", "tool": "Bash", "reason": "...", "summary": "deleting some files"}
{"type": "approval_closed", "id": "...", "approved": true}
{"type": "mic",             "open": true}
{"type": "session",         "id": "...", "cwd": "..."}
{"type": "focus",           "id": "<session id>"}
{"type": "delivery",        "id": "...", "status": "queued|delivered|refused"}
{"type": "error",           "message": "..."}
```

Shell → backend:

```json
{"type": "interrupt"}
{"type": "text",        "text": "typed turn, same path as a spoken one"}
{"type": "say",         "text": "speak this verbatim"}
{"type": "ptt",         "down": true}
{"type": "approve",     "approved": true}
{"type": "focus",       "id": "<session id>"}
{"type": "start_agent", "cwd": "/path/to/a/repo"}
{"type": "hello"}       // on connect: replay owned ids, focus and cwd
```

## Config

All via `.env`: `DEEPGRAM_MODEL`, `DEEPGRAM_VOICE`, `EOT_THRESHOLD`, `EOT_TIMEOUT_MS`,
`CLAUDE_CWD`, `CLAUDE_MODEL`, `CLAUDE_PERMISSION_MODE`, `APPROVAL_TIMEOUT_S`,
`APPROVAL_PORT`, `CANCEL_ON_INTERRUPT`, `PUSH_TO_TALK`, `PTT_TAIL_MS`, `SPOKEN_SENTENCES`,
`WS_HOST`, `WS_PORT`. The agents daemon reads `AGENTS_WS_PORT` (8767),
`AGENTS_TICK_S` and `AGENTS_SEND_DETAILS` (set 0 to keep prompt text and tool
arguments off the socket). `PTT_KEY` is read by the shell, not the backend, so it has
to be in the environment `run.sh` starts the app from (or `defaults write` it).

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
