#!/usr/bin/env bash
# Starts the agents daemon (unless launchd already runs it), the voice backend,
# and the notch shell. Ctrl-C or quitting the shell stops everything it started.
set -euo pipefail
cd "$(dirname "$0")"

PY=./.venv/bin/python
SHELL_DIR=shell/NotchAgent

die() { echo "run.sh: $*" >&2; exit 1; }
listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

[ -f .env ] || die "no .env — copy .env.example to .env and fill in your keys"
[ -x "$PY" ] || die "no .venv — pyenv local 3.11.6 && python -m venv .venv (see README)"
command -v claude >/dev/null || die "claude isn't on PATH"
for port in 8765 8766; do
  listening "$port" && die "port $port is taken — a backend is already running (lsof -iTCP:$port)"
done

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
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if listening 8767; then
  echo "agents daemon already running on :8767"
else
  "$PY" -m agentsd &
  PIDS+=($!)
fi

"$PY" -m backend.main &
BACKEND=$!
PIDS+=($BACKEND)

for _ in $(seq 1 50); do
  listening 8765 && break
  kill -0 "$BACKEND" 2>/dev/null || die "backend exited during startup — see the log above"
  sleep 0.2
done

"$SHELL_DIR/.build/release/NotchAgent" &
NOTCH=$!
PIDS+=($NOTCH)

# Whichever of backend or shell goes first takes the rest down with it.
# (macOS ships bash 3.2 — no `wait -n`.)
while kill -0 "$BACKEND" 2>/dev/null && kill -0 "$NOTCH" 2>/dev/null; do
  sleep 1
done
