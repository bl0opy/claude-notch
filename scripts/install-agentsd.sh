#!/usr/bin/env bash
# Runs the agents daemon at login. Uninstall: launchctl bootout gui/$(id -u)/com.notchagent.agentsd
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
LABEL="com.notchagent.agentsd"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"

# `claude` has to be on PATH: launchd hands a job almost nothing.
sed -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" -e "s|__PATH__|$PATH|g" \
  "service/$LABEL.plist" > "$TARGET"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$TARGET"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "installed $TARGET — logs at ~/Library/Logs/notch-agentsd.log"
