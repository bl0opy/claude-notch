#!/usr/bin/env bash
# Starts the notch at login, hidden until the Claude app opens. Installs the agents
# daemon too if launchd doesn't run it yet, since the notch is empty without it.
# Uninstall: launchctl bootout gui/$(id -u)/com.notchagent.notch
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
LABEL="com.notchagent.notch"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"

(cd shell/NotchAgent && swift build -c release)

launchctl print "gui/$(id -u)/com.notchagent.agentsd" >/dev/null 2>&1 || scripts/install-agentsd.sh

sed -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" "service/$LABEL.plist" > "$TARGET"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$TARGET"
echo "installed $TARGET — logs at ~/Library/Logs/notch-shell.log"
echo "allow NotchAgent under System Settings → Privacy & Security → Accessibility for the ⌃⌥ keys"
