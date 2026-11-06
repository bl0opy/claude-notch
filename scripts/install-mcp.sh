#!/usr/bin/env bash
# Gives every Claude Code session the notch_ask and notch_show tools.
# Uninstall: scripts/install-mcp.sh --uninstall
set -euo pipefail
cd "$(dirname "$0")/.."

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SERVER="$CLAUDE_HOME/hooks/notch_mcp.py"

mkdir -p "$CLAUDE_HOME/hooks"
# A copy, not a link: it has to survive this repo moving.
[ "${1:-install}" = "--uninstall" ] || cp hooks/notch_mcp.py "$SERVER"

MODE="${1:-install}"
claude mcp remove --scope user notch >/dev/null 2>&1 || true
[ "$MODE" = "--uninstall" ] || claude mcp add --scope user notch -- /usr/bin/python3 "$SERVER"

# Asking or showing you something isn't worth a permission prompt of its own.
/usr/bin/python3 - "$CLAUDE_HOME/settings.json" "$MODE" <<'PY'
import json, os, sys
path, mode = sys.argv[1:3]
settings = json.load(open(path)) if os.path.exists(path) else {}
allow = [r for r in settings.setdefault("permissions", {}).get("allow", []) if r != "mcp__notch"]
if mode != "--uninstall":
    allow.append("mcp__notch")
settings["permissions"]["allow"] = allow
with open(path, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

if [ "$MODE" = "--uninstall" ]; then
  rm -f "$SERVER"
  echo "removed the notch tools"
else
  echo "installed: new sessions get notch_ask and notch_show"
fi
