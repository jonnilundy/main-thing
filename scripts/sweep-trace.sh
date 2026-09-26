#!/bin/bash
# Records a SwiftUI Instruments trace attached to the running, installed Main Thing while someone
# sweeps the cursor over the open rows, then summarizes it. Open the notch and start sweeping when
# it says so; the summary says whether the notch opened and how many row hovers it saw.
#   scripts/sweep-trace.sh <out.trace> [seconds]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: scripts/sweep-trace.sh <out.trace> [seconds]}"
LIMIT="${2:-60}"
PID="$(pgrep -f 'MainThing.app/Contents/MacOS/MainThing' | head -1 || true)"
[[ -n "$PID" ]] || { echo "sweep-trace: Main Thing is not running" >&2; exit 1; }
rm -rf "$OUT" "$OUT.export"
echo "sweep-trace: recording pid $PID for ${LIMIT}s. Open the notch and sweep the rows now."
xcrun xctrace record --template SwiftUI --attach "$PID" --time-limit "${LIMIT}s" --output "$OUT" 2>&1 | /usr/bin/tail -1
"$ROOT/scripts/trace-summary.py" "$OUT"
