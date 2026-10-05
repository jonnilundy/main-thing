#!/bin/bash
# Checks, then the smoke test against a throwaway headless copy of the app.
# Never touches the installed app, its list or its config.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# One product per call: with two --product flags the Swift Build backend builds only the last one,
# and the checks would run a stale binary.
for product in main-thing-checks MainThing; do
    if ! OUT=$(swift build --disable-keychain --product "$product" 2>&1); then
        printf '%s\n' "$OUT" | /usr/bin/grep -E "error" >&2 || printf '%s\n' "$OUT" | /usr/bin/tail -20 >&2
        echo "test.sh: $product did not build" >&2
        exit 1
    fi
    printf '%s\n' "$OUT" | /usr/bin/grep -E "warning: unre" || true
done
BIN="$(swift build --disable-keychain --show-bin-path)"
"$BIN/main-thing-checks" | /usr/bin/tail -1
# The probes run side by side, each its own copy of the app in an invisible panel.
# A drawn hover at every height of the open card, for a hardware notch, the 30pt menu bar row of a
# Studio Display and a 24pt menu bar: synthesized moves, the pills read back from the rendered view.
# The card probe: every edit in the open card, end to end, clicks, drags and long presses as NSEvents.
# The adapter probe: built-in adapters with fake scripts, its own defaults suite and Keychain service.
PROBES="$(mktemp -d "${TMPDIR:-/tmp}/main-thing-probes.XXXXXX")"
PIDS=()
for screen in notch menubar menubar24; do
    "$BIN/MainThing" --bench-hover gap "$screen" > "$PROBES/gap-$screen" 2>&1 & PIDS+=($!)
done
"$BIN/MainThing" --probe-card > "$PROBES/card" 2>&1 & PIDS+=($!)
"$BIN/MainThing" --probe-adapters > "$PROBES/adapters" 2>&1 & PIDS+=($!)
# The band probe: the closed title's cap height middle and the empty list's shape under a hardware notch.
"$BIN/MainThing" --probe-band > "$PROBES/band" 2>&1 & PIDS+=($!)
FAILED=0
for pid in "${PIDS[@]}"; do wait "$pid" || FAILED=1; done
for screen in notch menubar menubar24; do /usr/bin/tail -1 "$PROBES/gap-$screen"; done
if [[ "$FAILED" == 1 ]] || ! /usr/bin/grep -q "all card checks passed" "$PROBES/card" || ! /usr/bin/grep -q "all adapter checks passed" "$PROBES/adapters" \
    || ! /usr/bin/grep -q "all band checks passed" "$PROBES/band"; then
    /usr/bin/grep -hE "FAIL|NOTHING|dead|probe:|probe-band:" "$PROBES"/* >&2
    rm -rf "$PROBES"
    echo "test.sh: a probe failed" >&2
    exit 1
fi
/usr/bin/tail -1 "$PROBES/card"
/usr/bin/tail -1 "$PROBES/adapters"
/usr/bin/tail -1 "$PROBES/band"
rm -rf "$PROBES"
# The built-in adapter scripts against a fake Linear and Open Brain server and a fake op.
if ! ADAPTERS_OUT=$(scripts/adapter-test.sh 2>&1); then
    printf '%s\n' "$ADAPTERS_OUT" | /usr/bin/grep FAIL >&2
    echo "test.sh: the adapter scripts failed" >&2
    exit 1
fi
printf '%s\n' "$ADAPTERS_OUT" | /usr/bin/tail -1

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
