#!/usr/bin/env bash
# Puts the notch's hook in front of every Claude Code session's permission
# prompts. The terminal dialog still shows — the notch is a second place to
# answer it — and with the agents daemon down the hook does nothing at all.
#
#   scripts/install-hooks.sh              install or update
#   scripts/install-hooks.sh --uninstall  remove the entries and the copied hook
set -euo pipefail
cd "$(dirname "$0")/.."

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SETTINGS="$CLAUDE_HOME/settings.json"
HOOK="$CLAUDE_HOME/hooks/notch_hook.py"
MODE="${1:-install}"
case "$MODE" in
  install|--uninstall) ;;
  *) echo "usage: $0 [--uninstall]" >&2; exit 2 ;;
esac

if [ "$MODE" = "install" ]; then
  mkdir -p "$CLAUDE_HOME/hooks"
  # A copy, not a link: the global hook must survive this repo moving.
  cp hooks/notch_hook.py "$HOOK"
fi

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak-notch"
fi

/usr/bin/python3 - "$SETTINGS" "$HOOK" "$MODE" <<'EOF'
import json, os, sys

settings_path, hook, mode = sys.argv[1:4]
settings = {}
if os.path.exists(settings_path):
    with open(settings_path, encoding="utf-8") as f:
        settings = json.load(f)

command = f"/usr/bin/python3 {hook}"
ours = lambda entry: any("notch_hook.py" in h.get("command", "") for h in entry.get("hooks", []))
wanted = {
    # Blocks for as long as the dialog is up; the inbox lets go before this.
    "PermissionRequest": {"matcher": "", "hooks": [{"type": "command", "command": command, "timeout": 600}]},
    "Stop": {"hooks": [{"type": "command", "command": command, "timeout": 5}]},
}

hooks = settings.setdefault("hooks", {})
for event in wanted:
    kept = [e for e in hooks.get(event, []) if not ours(e)]
    if mode == "install":
        kept.append(wanted[event])
    if kept:
        hooks[event] = kept
    else:
        hooks.pop(event, None)
if not hooks:
    settings.pop("hooks")

# The notch's sockets take a token from this file. A command running in Claude
# Code's sandbox can read most of your home folder, and with this file it could
# answer its own permission questions, so the sandbox is told not to.
token = "~/Library/Application Support/notch-agent/bridge-token"
filesystem = settings.setdefault("sandbox", {}).setdefault("filesystem", {})
deny = [p for p in filesystem.get("denyRead", []) if p != token]
if mode == "install":
    deny.append(token)
if deny:
    filesystem["denyRead"] = deny
else:
    filesystem.pop("denyRead", None)
if not filesystem:
    settings["sandbox"].pop("filesystem")
if not settings["sandbox"]:
    settings.pop("sandbox")

with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
EOF

if [ "$MODE" = "--uninstall" ]; then
  rm -f "$HOOK"
  echo "removed the notch hooks from $SETTINGS (backup: $SETTINGS.bak-notch)"
else
  echo "installed $HOOK into $SETTINGS (backup: $SETTINGS.bak-notch)"
  echo "running sessions pick it up too — it does nothing until the agents daemon is up"
fi
