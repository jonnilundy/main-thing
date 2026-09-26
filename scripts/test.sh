#!/bin/bash
# Checks, then the smoke test against a throwaway headless copy of the app.
# Never touches the installed app, its list or its config.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# One product per call: with two --product flags the Swift Build backend builds only the last one,
# and the checks would run a stale binary.
for product in main-thing-checks MainThing; do
    if ! OUT=$(swift build --product "$product" 2>&1); then
        printf '%s\n' "$OUT" | /usr/bin/grep -E "error" >&2 || printf '%s\n' "$OUT" | /usr/bin/tail -20 >&2
        echo "test.sh: $product did not build" >&2
        exit 1
    fi
    printf '%s\n' "$OUT" | /usr/bin/grep -E "warning: unre" || true
done
BIN="$(swift build --show-bin-path)"
"$BIN/main-thing-checks" | /usr/bin/tail -1
# A drawn hover at every height of the open card, for a hardware notch, the 30pt menu bar row of a
# Studio Display and a 24pt menu bar: synthesized moves in an invisible panel, the pills read back
# from the rendered view.
for screen in notch menubar menubar24; do
    "$BIN/MainThing" --bench-hover gap "$screen" | /usr/bin/tail -1
done
# Every edit in the open card, end to end: clicks, drags and long presses as NSEvents in the app.
if ! PROBE=$("$BIN/MainThing" --probe-card 2>&1); then
    printf '%s\n' "$PROBE" | /usr/bin/grep -E "FAIL|probe:" >&2
    exit 1
fi
printf '%s\n' "$PROBE" | /usr/bin/tail -1

[[ "${1:-}" == "--checks-only" ]] && exit 0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/main-thing-test.XXXXXX")"
PORT=$(( 20000 + RANDOM % 20000 ))
mkdir -p "$TMP/config"
MAIN_THING_HEADLESS=1 MAIN_THING_PORT=$PORT MAIN_THING_TASKS_FILE="$TMP/tasks.json" MAIN_THING_CONFIG_DIR="$TMP/config" \
    "$BIN/MainThing" > "$TMP/app.log" 2>&1 &
APP=$!
trap 'kill $APP 2>/dev/null || true; wait $APP 2>/dev/null || true; rm -rf "$TMP"' EXIT

for _ in $(seq 1 50); do
    curl -s --max-time 1 "http://localhost:$PORT/health" >/dev/null 2>&1 && break
    sleep 0.1
done

MAIN_THING_PORT=$PORT MAIN_THING_CONFIG_DIR="$TMP/config" scripts/smoke.sh | /usr/bin/tail -1
