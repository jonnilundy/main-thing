#!/bin/bash
# Build Main Thing, quit any running copy, install to ~/Applications, link the main-thing CLI, start it.
# Also retires the app's old name: NextUp.app and its nextup link go away, its list is copied on first launch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${HOME:?}/Applications/MainThing.app"
BIN_DIR="${HOME:?}/.local/bin"
PATTERN="MainThing.app/Contents/MacOS/MainThing"
OLD_APP="${HOME:?}/Applications/NextUp.app"
OLD_PATTERN="NextUp.app/Contents/MacOS/NextUp"

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

# The old name. Its list in Application Support stays; the new app copies it on first launch.
if [[ -d "$OLD_APP" ]]; then
    echo "old NextUp.app found, launch at login: $("$OLD_APP/Contents/MacOS/NextUp" --login status 2>/dev/null || echo unknown)"
    quit_running "$OLD_PATTERN" "com.jonnilundy.nextup"
    rm -rf "${OLD_APP:?}"
    echo "removed $OLD_APP"
fi
if [[ -L "$BIN_DIR/nextup" && "$(readlink "$BIN_DIR/nextup")" == "$ROOT/bin/nextup" ]]; then
    rm "$BIN_DIR/nextup"
    echo "removed the old link $BIN_DIR/nextup"
fi

quit_running "$PATTERN" "com.jonnilundy.mainthing"

mkdir -p "${HOME:?}/Applications"
rm -rf "${DEST:?}"
cp -R "$ROOT/build/MainThing.app" "$DEST"
open "$DEST"

mkdir -p "$BIN_DIR"
ln -sf "$ROOT/bin/main-thing" "$BIN_DIR/main-thing"
echo "linked $BIN_DIR/main-thing -> $ROOT/bin/main-thing"
# The name before 0.3: an old link becomes the alias, which says so and runs main-thing (until 0.4).
if [[ -L "$BIN_DIR/mainthing" ]]; then
    ln -sfn "$ROOT/bin/mainthing" "$BIN_DIR/mainthing"
    echo "linked $BIN_DIR/mainthing -> $ROOT/bin/mainthing, the alias for the old name"
fi
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR is not on your PATH. Add it, for example: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo "installed and started $DEST"
echo "check: main-thing health"
