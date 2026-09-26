#!/bin/bash
# Build Main Thing, quit any running copy, install to ~/Applications, link the main-thing CLI, start it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${HOME:?}/Applications/MainThing.app"
BIN_DIR="${HOME:?}/.local/bin"
PATTERN="MainThing.app/Contents/MacOS/MainThing"

quit_running() {
    local pattern="$1" bundle_id="$2"
    if pgrep -f "$pattern" >/dev/null; then
        echo "quitting the running copy of $bundle_id"
        osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || pkill -f "$pattern" || true
        for _ in $(seq 1 20); do
            pgrep -f "$pattern" >/dev/null || break
            sleep 0.25
        done
        pgrep -f "$pattern" >/dev/null && pkill -9 -f "$pattern" || true
    fi
}

"$ROOT/scripts/build-app.sh"

quit_running "$PATTERN" "com.jonnilundy.mainthing"

mkdir -p "${HOME:?}/Applications"
rm -rf "${DEST:?}"
cp -R "$ROOT/build/MainThing.app" "$DEST"
open "$DEST" 2>/dev/null || { sleep 1; open "$DEST"; }

mkdir -p "$BIN_DIR"
ln -sf "$ROOT/bin/main-thing" "$BIN_DIR/main-thing"
echo "linked $BIN_DIR/main-thing -> $ROOT/bin/main-thing"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR is not on your PATH. Add it, for example: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo "installed and started $DEST"
echo "check: main-thing health"
