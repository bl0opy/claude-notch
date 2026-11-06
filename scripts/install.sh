#!/usr/bin/env bash
# Everything, in order: Python deps, the permission hook, the daemon and the notch
# at login, and the notch tools. Safe to run again after pulling.
#
#   scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

command -v claude >/dev/null || { echo "install Claude Code first: https://code.claude.com" >&2; exit 1; }
command -v swift >/dev/null || { echo "install the Xcode command line tools first: xcode-select --install" >&2; exit 1; }

if [ ! -x .venv/bin/python ]; then
  if command -v pyenv >/dev/null && pyenv versions --bare | grep -qx 3.11.6; then
    pyenv local 3.11.6
  fi
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' \
    || { echo "needs Python 3.11 or newer (python3 is $(python3 --version))" >&2; exit 1; }
  python3 -m venv .venv
fi
.venv/bin/pip install -q -r requirements.txt
[ -f settings.json ] || cp settings.example.json settings.json

scripts/install-hooks.sh
scripts/install-notch.sh    # installs the daemon too
scripts/install-mcp.sh

cat <<'DONE'

done. The notch shows while the Claude app is open; hover it to open the panel.
  - Allow NotchAgent in System Settings → Privacy & Security → Accessibility for ⌃⌥T and ⌃⌥Y/N.
  - If this repo is in Documents, macOS asks for python3 and NotchAgent to read it: allow both.
  - Sessions already open pick up the hook now and notch_ask / notch_show when restarted.
DONE
