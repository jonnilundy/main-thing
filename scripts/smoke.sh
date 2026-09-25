#!/bin/bash
# Exercise every route with curl and the nextup CLI against the running app.
# Exits non-zero on any mismatch. The list that was there before the run is put back at the end.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${NEXTUP_PORT:-7788}"
BASE="http://localhost:$PORT"
CLI="$ROOT/bin/nextup"
fails=0

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# expect <name> <status> <exact body or ''> <curl args...>
expect() {
    local name="$1" want_status="$2" want_body="$3"
    shift 3
    local out rc status body
    out=$(curl -s -g -o - -w $'\n%{http_code}' "$@" 2>&1)
    rc=$?
    if [[ $rc -ne 0 ]]; then
        fail "$name: curl exit $rc: $out"
        return
    fi
    status="${out##*$'\n'}"
    body="${out%$'\n'*}"
    if [[ "$status" != "$want_status" ]]; then
        fail "$name: got $status $body, wanted $want_status"
        return
    fi
    if [[ -n "$want_body" && "$body" != "$want_body" ]]; then
        fail "$name: got $body, wanted $want_body"
        return
    fi
    pass "$name -> $status $body"
}

# same <name> <expected> <actual>
same() {
    if [[ "$2" == "$3" ]]; then pass "$1 -> $3"; else fail "$1: got [$3], wanted [$2]"; fi
}

original=$(curl -s "$BASE/tasks")
if [[ "$original" != \{\"tasks\":* ]]; then
    echo "FAIL app is not answering on $BASE (got: $original)"
    exit 1
fi
echo "saved list: $original"

expect "GET /health" 200 '{"ok":true,"version":"0.1.0"}' "$BASE/health"
expect "PUT /tasks array, trims and drops blanks" 200 '{"tasks":["Smoke A","Smoke B"]}' \
    -X PUT --data-binary '["Smoke A","  Smoke B  ","", "   "]' "$BASE/tasks"
expect "GET /tasks" 200 '{"tasks":["Smoke A","Smoke B"]}' "$BASE/tasks"
expect "PUT /tasks object form" 200 '{"tasks":["Smoke C","Smoke D"]}' \
    -X PUT --data-binary '{"tasks":["Smoke C","Smoke D"]}' "$BASE/tasks"
expect "PUT /tasks with a text Content-Type" 200 '{"tasks":["Smoke E","Smoke F"]}' \
    -X PUT -H 'Content-Type: text/plain' --data-binary '["Smoke E","Smoke F"]' "$BASE/tasks"
expect "POST /tasks/done" 200 '{"tasks":["Smoke F"]}' -X POST "$BASE/tasks/done"
expect "POST /tasks/done to empty" 200 '{"tasks":[]}' -X POST "$BASE/tasks/done"
expect "POST /tasks/done on empty stays empty" 200 '{"tasks":[]}' -X POST "$BASE/tasks/done"
expect "PUT /tasks bad JSON" 400 '{"error":"body is not valid JSON"}' -X PUT --data-binary 'not json' "$BASE/tasks"
expect "PUT /tasks non-string item" 400 '{"error":"item 0 is not a string"}' -X PUT --data-binary '[1,2]' "$BASE/tasks"
expect "PUT /tasks empty body" 400 '' -X PUT "$BASE/tasks"
expect "GET /nope" 404 '' "$BASE/nope"
expect "DELETE /tasks" 405 '' -X DELETE "$BASE/tasks"
expect "GET /tasks/done" 405 '' "$BASE/tasks/done"
expect "POST /health" 405 '' -X POST "$BASE/health"

big=$(printf '["%*s"]' 70000 '' | tr ' ' 'a')
expect "PUT /tasks 70 KB body" 413 '{"error":"body over 64 KB"}' -X PUT --data-binary "$big" "$BASE/tasks"

expect "GET /tasks with Origin" 403 '{"error":"requests with an Origin header are refused"}' \
    -H "Origin: http://localhost:$PORT" "$BASE/tasks"
expect "PUT /tasks with Origin" 403 '' -X PUT -H 'Origin: null' --data-binary '["x"]' "$BASE/tasks"
expect "GET /health with a foreign Host" 403 '' -H 'Host: evil.example' "$BASE/health"
expect "GET /health with Host other.localhost" 403 '' -H "Host: other.localhost:$PORT" "$BASE/health"
expect "GET /health with Host nextup.localhost" 200 '{"ok":true,"version":"0.1.0"}' -H "Host: nextup.localhost:$PORT" "$BASE/health"
expect "GET /health at http://nextup.localhost (resolved to loopback)" 200 '{"ok":true,"version":"0.1.0"}' \
    --resolve "nextup.localhost:$PORT:127.0.0.1" "http://nextup.localhost:$PORT/health"
expect "GET /health over IPv6" 200 '{"ok":true,"version":"0.1.0"}' -6 "http://[::1]:$PORT/health"
expect "GET /health via 127.0.0.1" 200 '{"ok":true,"version":"0.1.0"}' "http://127.0.0.1:$PORT/health"

echo "--- nextup CLI"
same "nextup health" '{"ok":true,"version":"0.1.0"}' "$(NEXTUP_PORT=$PORT "$CLI" health)"
same "nextup set with quotes and an apostrophe" $'She said "go"\nJonni\'s memo\nTab\\there' \
    "$(NEXTUP_PORT=$PORT "$CLI" set 'She said "go"' "Jonni's memo" 'Tab\there')"
same "nextup prints the current task" 'She said "go"' "$(NEXTUP_PORT=$PORT "$CLI")"
same "nextup list" $'She said "go"\nJonni\'s memo\nTab\\there' "$(NEXTUP_PORT=$PORT "$CLI" list)"
same "nextup done" $'Jonni\'s memo\nTab\\there' "$(NEXTUP_PORT=$PORT "$CLI" done)"
same "nextup set - from stdin" $'Line one\nLine "two"' "$(printf 'Line one\nLine "two"\n' | NEXTUP_PORT=$PORT "$CLI" set -)"
same "nextup unknown command exits 1" "1" "$(NEXTUP_PORT=$PORT "$CLI" nope >/dev/null 2>&1; echo $?)"
same "nextup on a dead port says not running" "1" "$(NEXTUP_PORT=1 "$CLI" >/dev/null 2>&1; echo $?)"

expect "restore the saved list" 200 "$original" -X PUT --data-binary "$original" "$BASE/tasks"

echo
if [[ $fails -eq 0 ]]; then
    echo "smoke: all checks passed"
    exit 0
fi
echo "smoke: $fails check(s) failed"
exit 1
