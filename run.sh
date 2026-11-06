#!/usr/bin/env bash
# Starts the agents daemon (unless launchd already runs a current one), the voice
# backend, and the notch shell. Ctrl-C or quitting the shell stops everything it
# started. Everything each process prints also goes to ~/Library/Logs/notch-agent/.
set -euo pipefail
cd "$(dirname "$0")"

PY=./.venv/bin/python
SHELL_DIR=shell/NotchAgent
LABEL=com.notchagent.agentsd
LOGS="$HOME/Library/Logs/notch-agent"
AGENTS_PORT="${AGENTS_WS_PORT:-8767}"
WINDOW_PORT="${AGENTS_WINDOW_PORT:-8768}"

die() { echo "run.sh: $*" >&2; exit 1; }
listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
listener_pid() { lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1; }
launchd_owns_daemon() { launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; }
NOTCH_LABEL=com.notchagent.notch
NOTCH_PLIST="$HOME/Library/LaunchAgents/$NOTCH_LABEL.plist"
NOTCH_STEPPED_ASIDE=

wait_for_port() {
  for _ in $(seq 1 50); do
    listening "$1" && return 0
    sleep 0.2
  done
  return 1
}

[ -x "$PY" ] || die "no .venv — pyenv local 3.11.6 && python -m venv .venv (see README)"
command -v claude >/dev/null || die "claude isn't on PATH"
mkdir -p "$LOGS"

[ -f settings.json ] || cp settings.example.json settings.json
# Voice is paused: it only starts with "voice": true in settings.json. Without it
# there's no voice backend: no mic, no
# speech models, and nothing that needs Apple Silicon. The notch is typed to.
VOICE=$("$PY" -c 'import json; print(json.load(open("settings.json")).get("voice", False) is True)' 2>/dev/null || echo False)
if [ "$VOICE" = True ]; then
  listening 8765 && die "port 8765 is taken — a backend is already running (lsof -iTCP:8765)"
  "$PY" -c 'import pipecat' 2>/dev/null \
    || die "voice is on but its packages aren't installed — .venv/bin/pip install -r requirements-voice.txt, or set \"voice\": false in settings.json"
fi

# SwiftPM bakes absolute paths into its module cache, so a moved repo fails to
# build until the cache is gone.
build_shell() { (cd "$SHELL_DIR" && swift build -c release 2>&1); }
echo "building the notch shell…"
if ! out=$(build_shell); then
  if grep -q "was compiled with module cache path" <<<"$out"; then
    echo "stale build cache from another checkout path — rebuilding clean"
    rm -rf "$SHELL_DIR/.build"
    out=$(build_shell) || { echo "$out" >&2; die "swift build failed"; }
  else
    echo "$out" >&2
    die "swift build failed"
  fi
fi

PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  if [ -n "$NOTCH_STEPPED_ASIDE" ]; then
    launchctl bootstrap "gui/$(id -u)" "$NOTCH_PLIST" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# A daemon from before the terminal window serves the roster but not the
# window, so it's restarted on this checkout rather than quietly reused.
if listening "$AGENTS_PORT" && ! listening "$WINDOW_PORT"; then
  if launchd_owns_daemon; then
    echo "the launchd agents daemon predates the terminal window — restarting it on this code"
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
    wait_for_port "$WINDOW_PORT" || die "the launchd daemon didn't come back with the window — see $HOME/Library/Logs/notch-agentsd.log"
  else
    stale=$(listener_pid "$AGENTS_PORT")
    if ps -o command= -p "$stale" 2>/dev/null | grep -q "agentsd"; then
      echo "stopping an old agents daemon (pid $stale) that has no terminal window"
      kill "$stale"
      for _ in $(seq 1 25); do listening "$AGENTS_PORT" || break; sleep 0.2; done
    else
      die "port $AGENTS_PORT is taken by something that isn't the agents daemon (lsof -iTCP:$AGENTS_PORT)"
    fi
  fi
fi

if listening "$AGENTS_PORT"; then
  echo "agents daemon already running on :$AGENTS_PORT$(launchd_owns_daemon && echo ' (launchd)')"
elif listening 8766; then
  die "port 8766 is taken but no agents daemon on :$AGENTS_PORT — an old backend? (lsof -iTCP:8766)"
else
  "$PY" -m agentsd > >(tee -a "$LOGS/agentsd.log") 2>&1 &
  PIDS+=($!)
  export NOTCH_OWNS_DAEMON=1
  wait_for_port "$WINDOW_PORT" || die "the agents daemon didn't start — see $LOGS/agentsd.log"
fi

BACKEND=
if [ "$VOICE" = True ]; then
  "$PY" -m backend.main > >(tee -a "$LOGS/backend.log") 2>&1 &
  BACKEND=$!
  PIDS+=($BACKEND)

  for _ in $(seq 1 50); do
    listening 8765 && break
    kill -0 "$BACKEND" 2>/dev/null || die "backend exited during startup — see $LOGS/backend.log"
    sleep 0.2
  done
fi

# One notch at a time: the login one steps aside, and comes back on the way out.
if launchctl print "gui/$(id -u)/$NOTCH_LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/$NOTCH_LABEL" 2>/dev/null || true
  NOTCH_STEPPED_ASIDE=1
fi

NOTCH_SETTINGS="$PWD/settings.json" "$SHELL_DIR/.build/release/NotchAgent" > >(tee -a "$LOGS/shell.log") 2>&1 &
NOTCH=$!
PIDS+=($NOTCH)

cat <<EOF

  notch agent is up
  settings, quit    right-click the notch
  $([ "$VOICE" = True ] && echo "talk              hold your talk key" || echo "voice             off — ⌃⌥T types to an agent")
  type              ⌃⌥T from any app
  logs              $LOGS

EOF

# Whichever of backend or shell goes first takes the rest down with it.
# (macOS ships bash 3.2 — no `wait -n`.)
backend_up() { [ -z "$BACKEND" ] || kill -0 "$BACKEND" 2>/dev/null; }
while backend_up && kill -0 "$NOTCH" 2>/dev/null; do
  sleep 1
done
if ! backend_up; then
  echo "run.sh: the voice backend exited — last lines of $LOGS/backend.log:" >&2
  tail -n 15 "$LOGS/backend.log" >&2 || true
fi
