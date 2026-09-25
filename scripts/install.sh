#!/bin/bash
# Build NextUp, quit any running copy, install to ~/Applications, link the nextup CLI, start it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${HOME:?}/Applications/NextUp.app"
BIN_DIR="${HOME:?}/.local/bin"
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

mkdir -p "$BIN_DIR"
ln -sf "$ROOT/bin/nextup" "$BIN_DIR/nextup"
echo "linked $BIN_DIR/nextup -> $ROOT/bin/nextup"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR is not on your PATH. Add it, for example: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo "installed and started $DEST"
echo "check: nextup health"
