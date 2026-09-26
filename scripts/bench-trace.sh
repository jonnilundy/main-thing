#!/bin/bash
# Records a SwiftUI Instruments trace of the hover bench (`MainThing --bench-hover`) and summarizes
# it. No cursor, no real notch: the bench sweeps its own invisible panel with synthesized moves.
#   scripts/bench-trace.sh <out.trace> [seconds]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: scripts/bench-trace.sh <out.trace> [seconds]}"
SECONDS_SWEEP="${2:-6}"
cd "$ROOT"
swift build -c release --product MainThing 2>&1 | /usr/bin/grep -E "error" && exit 1
rm -rf "$OUT" "$OUT.export"
# The sweep starts after 4s, time for Instruments to attach.
MAIN_THING_BENCH_DELAY=4 .build/release/MainThing --bench-hover "$SECONDS_SWEEP" > "$OUT.bench.txt" 2>&1 &
PID=$!
sleep 1
xcrun xctrace record --template SwiftUI --attach "$PID" --time-limit "$(( SECONDS_SWEEP + 5 ))s" --output "$OUT" > "$OUT.record.txt" 2>&1 || true
wait "$PID" || true
cat "$OUT.bench.txt"
scripts/trace-summary.py "$OUT"
