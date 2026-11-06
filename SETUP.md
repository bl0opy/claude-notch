# Setup and testing

How this machine is set up, and how to check that each piece works. The
design and the full reference are in `README.md`.

## What runs

| Process | Port | Needs | What it does |
|---|---|---|---|
| agents daemon (`python -m agentsd`) | :8767 ws, :8766 tcp | nothing | lists every Claude Code session and holds every open permission question |
| voice backend (`python -m backend.main`) | :8765 ws | `claude` | mic, speech to text, voice agent, text to speech, spoken commands |
| notch app (`shell/NotchAgent`) | — | Accessibility | the notch, approval cards, hotkeys, push-to-talk |
| global hook (`~/.claude/hooks/notch_hook.py`) | — | the daemon | sends every session's permission prompts to the daemon |

The daemon and the notch app work without the voice backend: you get cards,
clicks and hotkeys, but nothing spoken.

## One-time setup

```bash
pyenv local 3.11.6 && python -m venv .venv
.venv/bin/pip install -r requirements-voice.txt   # or requirements.txt, with "voice": false in settings.json
scripts/install-hooks.sh           # add the permission hook to ~/.claude/settings.json
```

- `claude` must be on PATH and logged in.
- **Accessibility:** System Settings → Privacy & Security → Accessibility.
  Allow whichever app launches the notch (Terminal when you use `./run.sh`).
  Push-to-talk, ⌥Space and ⌃⌥Y / N / J all need it.
- **Automation:** macOS asks the first time ↗ selects a tab in Terminal or iTerm2.
- `scripts/install-hooks.sh --uninstall` removes the hook again. The settings file
  is backed up to `~/.claude/settings.json.bak-notch` either way.
- Optional: `scripts/install-agentsd.sh` runs the daemon at login under launchd,
  so approvals work without `./run.sh`.
- The notch's sockets ask for a token from `~/Library/Application Support/notch-agent/bridge-token`,
  made the first time the daemon starts. After pulling this change, run `scripts/install-hooks.sh`
  again: a hook without the token can't put up cards, and sessions fall back to their own prompts.
  Under Claude Code's sandbox the file is only out of reach with `blockReadsOutsideWorkingDirectories`
  on, or with that path in `sandbox.filesystem.denyRead`. Without one of those, a sandboxed
  command can read it and answer permission questions.
- Optional: `scripts/install-mcp.sh` gives every session two tools: `notch_ask` puts a small
  form in the notch and waits for your answers, and `notch_show` puts up progress, a table or
  a diff. Sessions fill in fixed card types and can't send interface code, and an answer only
  goes back to the session that asked, so neither can approve anything.
- Optional: `scripts/install-notch.sh` does the same for the notch, and installs the
  daemon if it isn't yet. The notch stays hidden until the Claude desktop app opens
  and goes away when it quits; turn that off with "only while the Claude app is open"
  in Settings, or `"follow_claude_app": false`. Without the app installed it's always
  up. Quitting it from its right-click menu keeps it off until your next login.

## Running

```bash
./run.sh                                         # daemon (unless launchd has it) + backend + notch
.venv/bin/python -m agentsd                      # daemon only
shell/NotchAgent/.build/release/NotchAgent       # notch only (build with ./run.sh or swift build -c release)
.venv/bin/python scripts/mock_agents.py          # fake daemon with fake cards, for UI work
```

`run.sh` builds the notch first and stops with the error if the build fails.
If you move the repo, it clears SwiftPM's stale cache and builds again. Ctrl-C,
or quitting the notch, stops everything it started.

## When a card shows up

A card only appears when Claude Code would actually show you a permission prompt.

**Gotcha:** `~/.claude/settings.json` sets `permissions.defaultMode` to `auto`.
In auto mode Claude Code runs most commands without asking, so most of the time
there's nothing for the notch to show. To see cards, start a session that asks:

```bash
claude --permission-mode default     # or shift+tab in a running session
```

Agents started from the notch's **+ agent** run `claude -p` in auto mode. For
those, the hook asks about the risky ones only: `rm -rf`, `git push`, package
installs, writes outside the project, `WebFetch`. With no daemon running, those
are denied.

## Test checklist

Start `./run.sh`, then open a Terminal tab in any repo and run
`claude --permission-mode default`.

| # | Do | Expect |
|---|---|---|
| 1 | Ask it to "run `touch /tmp/notch-test`" | Card in the notch while the terminal prompt is also up ✅ verified 2026-09-16 |
| 2 | Click **allow** | Terminal prompt closes, command runs |
| 3 | Trigger again, press ⌃⌥Y from any app | Same as 2 |
| 4 | Trigger again, answer in the terminal | Card disappears within about 1s |
| 5 | Trigger again, hold right ⌥, say "yes" | "Allowed pose-lab." |
| 6 | Ask for `git push --dry-run`, say "yes" | Refused: "say approve <project>" |
| 7 | Say "approve <project>" | Allowed |
| 8 | Prompts pending in two repos, say "what's waiting" | One sentence naming both |
| 9 | "deny <project>" | Only that one is denied |
| 10 | ⌃⌥J or ↗ | That Terminal tab comes forward |
| 11 | "go to <project>", then "back" | Mic moves, then returns to the voice agent |
| 12 | A 30s+ job in a session you aren't focused on | "<project> is done." and a "done after …" line in the notch (a sound instead of the voice with voice off) |
| 14 | + agent, type a bare repo name, tab, ↩ | Suggestions under the field, then the terminal window opens on the new agent |
| 15 | ⌃⌥T from another app, type a line, ↩, esc | The line reaches the focused agent; the keyboard goes back to the app you were in |
| 13 | Quit `./run.sh`, trigger a prompt | Plain Claude Code behaviour, no delay |

Automated checks, no audio or API keys needed:

```bash
.venv/bin/python scripts/inbox_smoke.py      # inbox + the real hook
.venv/bin/python scripts/commands_smoke.py   # spoken command grammar
.venv/bin/python scripts/fleet_smoke.py      # voice answers questions end to end
.venv/bin/python scripts/turns_smoke.py      # end-of-turn from the roster and the hook
.venv/bin/python scripts/type_smoke.py       # typing to a session with no voice backend
(cd shell/NotchAgent && swift test)          # the notch: cards, notices, modes, typing, + agent
```

## Troubleshooting

| Symptom | Check |
|---|---|
| No card | Is the session in auto mode? Is the daemon up (`lsof -iTCP:8766`)? Is the hook installed (`grep notch_hook ~/.claude/settings.json`)? |
| "agents daemon offline" in the dashboard | Nothing on :8767. Start `./run.sh` or `scripts/install-agentsd.sh` |
| `run.sh`: port 8765 taken | A backend is still running. `lsof -iTCP:8765`, then kill it |
| Hotkeys or push-to-talk do nothing | Accessibility permission for the launching app |
| Swift build error mentioning "module cache path" | The repo moved. `run.sh` fixes it; by hand, `rm -rf shell/NotchAgent/.build` |
| Nothing is spoken | Is the voice backend running? First run downloads the Kokoro model (~350 MB). With `TTS_BACKEND=deepgram`, is `DEEPGRAM_API_KEY` set? |

Daemon logs: the `./run.sh` output, or `~/Library/Logs/notch-agentsd.log` under launchd.

## Verified behaviour (Claude Code 2.1.273)

- The terminal prompt and the hook run at the same time. Answering in either place closes the other.
- `~/.claude/sessions/<pid>.json` shows `waiting` / `permission prompt` exactly while the prompt is up.
- Sessions that were already running pick up changes to `~/.claude/settings.json` without a restart.
- Sessions started from inside another Claude Code session write no registry file and no transcript.

## Where this is going: idle mode

Not built yet.

- **Always on, from login:** the daemon (launchd) and the notch app (as a Login Item, once packaged as a `.app`). Cheap: no mic, no API calls.
- **Voice on demand:** the first right-⌥ hold starts the backend (about 2s the first time). It shuts down after about 15 minutes with no speech, which closes the mic, the speech models and `claude -p`.
- **Daemon polling:** slows down when every session is idle.
