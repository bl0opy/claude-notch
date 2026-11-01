#!/usr/bin/env bash
# Gives every Claude Code session the notch_ask and notch_show tools.
# Uninstall: claude mcp remove --scope user notch
set -euo pipefail
cd "$(dirname "$0")/.."

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SERVER="$CLAUDE_HOME/hooks/notch_mcp.py"

mkdir -p "$CLAUDE_HOME/hooks"
# A copy, not a link: it has to survive this repo moving.
cp hooks/notch_mcp.py "$SERVER"

claude mcp remove --scope user notch >/dev/null 2>&1 || true
claude mcp add --scope user notch -- /usr/bin/python3 "$SERVER"
echo "installed: new sessions get notch_ask and notch_show"
echo "so they don't ask permission to ask you something, add \"mcp__notch\" to permissions.allow in $CLAUDE_HOME/settings.json"
