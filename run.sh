#!/usr/bin/env bash
# Starts the Python voice backend and the SwiftUI notch shell together.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "no .env — copy .env.example to .env and fill in your keys" >&2
  exit 1
fi

./.venv/bin/python -m backend.main &
BACKEND=$!
trap 'kill $BACKEND 2>/dev/null || true' EXIT

(cd shell/NotchAgent && swift build -c release >/dev/null)
./shell/NotchAgent/.build/release/NotchAgent
