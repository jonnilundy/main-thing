#!/bin/bash
# Checks, then the smoke test against a throwaway headless copy of the app.
# Never touches the installed app, its list or its config.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build --product mainthing-checks --product MainThing 2>&1 | /usr/bin/grep -E "error|warning: unre" || true
BIN="$(swift build --show-bin-path)"
"$BIN/mainthing-checks" | /usr/bin/tail -1

[[ "${1:-}" == "--checks-only" ]] && exit 0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mainthing-test.XXXXXX")"
PORT=$(( 20000 + RANDOM % 20000 ))
mkdir -p "$TMP/config"
MAINTHING_HEADLESS=1 MAINTHING_PORT=$PORT MAINTHING_TASKS_FILE="$TMP/tasks.json" MAINTHING_CONFIG_DIR="$TMP/config" \
    "$BIN/MainThing" > "$TMP/app.log" 2>&1 &
APP=$!
trap 'kill $APP 2>/dev/null; wait $APP 2>/dev/null; rm -rf "$TMP"' EXIT

for _ in $(seq 1 50); do
    curl -s --max-time 1 "http://localhost:$PORT/health" >/dev/null 2>&1 && break
    sleep 0.1
done

MAINTHING_PORT=$PORT MAINTHING_CONFIG_DIR="$TMP/config" scripts/smoke.sh | /usr/bin/tail -1
