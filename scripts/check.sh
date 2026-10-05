#!/bin/bash
# The one check before a push.
#
#   scripts/check.sh            builds MainThing and main-thing-checks, runs the checks binary and
#                               the adapter scripts. No window, no focus, no cursor: safe on the Mac
#                               you are typing on. The pre-push hook runs this.
#   scripts/check.sh --probes   runs scripts/test.sh --checks-only instead (the above plus the hover,
#                               card and adapter probes). The card probe takes the keyboard focus, so
#                               run it in CI or a VM, never on a desk Mac. CI runs this.
#
# The exit code is the failing step's exit code (0 when all pass). The last line is always
# "CHECK PASS: ..." or "CHECK FAIL (<step>): ...". Never pipe it before && (the pipe hides the exit code).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
LOG="$ROOT/build/check.log"
: > "$LOG"

fail() { echo "CHECK FAIL ($1): $2 (log: build/check.log)"; exit "$3"; }

if [[ "${1:-}" == "--probes" ]]; then
    scripts/test.sh --checks-only 2>&1 | tee -a "$LOG"
    code=$?
    (( code )) && fail "test.sh --checks-only" "$(/usr/bin/grep -m1 -E 'test.sh:|error' "$LOG")" "$code"
    echo "CHECK PASS: build, checks, probes, adapter scripts"
    exit 0
fi

# 1. build, one product per call (with two --product flags the Swift Build backend builds only the last)
for product in main-thing-checks MainThing; do
    swift build --product "$product" >> "$LOG" 2>&1
    code=$?
    (( code )) && fail "build $product" "$( { /usr/bin/grep -m1 -E ':[0-9]+:[0-9]+: .*error' "$LOG" || /usr/bin/grep -m1 -E 'error:' "$LOG"; } | perl -pe 's/\e\[[0-9;]*m//g' | cut -c1-200)" "$code"
done
BIN="$(swift build --show-bin-path)"

# 2. the checks binary (pure logic, no UI)
"$BIN/main-thing-checks" >> "$LOG" 2>&1
code=$?
(( code )) && fail "main-thing-checks" "$(/usr/bin/grep -m1 -iE 'fail' "$LOG")" "$code"
checks=$(/usr/bin/tail -1 "$LOG")
echo "$checks"

# 3. the built-in adapter scripts against fake servers and a fake op
scripts/adapter-test.sh >> "$LOG" 2>&1
code=$?
(( code )) && fail "adapter scripts" "$(/usr/bin/grep -m1 FAIL "$LOG")" "$code"
adapters=$(/usr/bin/tail -1 "$LOG")
echo "$adapters"

echo "CHECK PASS: build, checks, adapter scripts (probes: scripts/check.sh --probes, in CI or a VM)"
