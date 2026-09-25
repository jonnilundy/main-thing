#!/bin/bash
# Build NextUp, quit any running copy, install to ~/Applications and start it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${HOME:?}/Applications/NextUp.app"
PATTERN="NextUp.app/Contents/MacOS/NextUp"

"$ROOT/scripts/build-app.sh"

if pgrep -f "$PATTERN" >/dev/null; then
    echo "quitting the running copy"
    osascript -e 'tell application id "com.jonnilundy.nextup" to quit' >/dev/null 2>&1 || pkill -f "$PATTERN" || true
    for _ in $(seq 1 20); do
        pgrep -f "$PATTERN" >/dev/null || break
        sleep 0.25
    done
    pgrep -f "$PATTERN" >/dev/null && pkill -9 -f "$PATTERN" || true
fi

mkdir -p "${HOME:?}/Applications"
rm -rf "${DEST:?}"
cp -R "$ROOT/build/NextUp.app" "$DEST"
open "$DEST"

echo "installed and started $DEST"
echo "check: curl -s http://127.0.0.1:7788/health"
