#!/bin/bash
# Exercise every route with curl and the main-thing CLI against the running app, hooks included.
# Exits non-zero on any mismatch. The list that was there before the run is put back at the end.
# MAIN_THING_PORT picks the app, MAIN_THING_CONFIG_DIR its hooks folder (see README, a second copy for tests).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${MAIN_THING_PORT:-}"
if [[ -z "$PORT" ]]; then
    echo "smoke.sh rewrites the list it tests. Run scripts/test.sh, which points it at a throwaway copy."
    exit 1
fi
BASE="http://localhost:$PORT"
VERSION=$(sed -n 's/^public let MainThingVersion = "\([^"]*\)"$/\1/p' "$ROOT/Sources/MainThingCore/Version.swift")
HEALTH="{\"ok\":true,\"port\":$PORT,\"version\":\"$VERSION\"}"
CLI="$ROOT/bin/main-thing"
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
original_hidden=$(curl -s "$BASE/hidden")

expect "GET /health" 200 "$HEALTH" "$BASE/health"
expect "PUT /tasks array, trims and drops blanks" 200 '{"tasks":[{"title":"Smoke A"},{"title":"Smoke B"}]}' \
    -X PUT --data-binary '["Smoke A","  Smoke B  ","", "   "]' "$BASE/tasks"
expect "GET /tasks" 200 '{"tasks":[{"title":"Smoke A"},{"title":"Smoke B"}]}' "$BASE/tasks"
expect "PUT /tasks object form" 200 '{"tasks":[{"title":"Smoke C"},{"title":"Smoke D"}]}' \
    -X PUT --data-binary '{"tasks":["Smoke C","Smoke D"]}' "$BASE/tasks"
expect "PUT /tasks with a text Content-Type" 200 '{"tasks":[{"title":"Smoke E"},{"title":"Smoke F"}]}' \
    -X PUT -H 'Content-Type: text/plain' --data-binary '["Smoke E","Smoke F"]' "$BASE/tasks"
expect "PUT /tasks with refs, strings and objects mixed" 200 '{"tasks":[{"title":"Smoke E"},{"ref":"smoke:1","title":"Smoke F"}]}' \
    -X PUT --data-binary '["Smoke E",{"title":"Smoke F","ref":"smoke:1"}]' "$BASE/tasks"
expect "GET /tasks returns the ref" 200 '{"tasks":[{"title":"Smoke E"},{"ref":"smoke:1","title":"Smoke F"}]}' "$BASE/tasks"
expect "PUT /tasks bad ref" 400 '{"error":"item 0: ref must look like <adapter>:<id>"}' \
    -X PUT --data-binary '[{"title":"x","ref":"nocolon"}]' "$BASE/tasks"
expect "PUT /tasks duplicate ref" 400 '{"error":"item 1 repeats the ref smoke:1"}' \
    -X PUT --data-binary '[{"title":"x","ref":"smoke:1"},{"title":"y","ref":"smoke:1"}]' "$BASE/tasks"
expect "PUT /tasks object without title" 400 '{"error":"item 0 needs a \"title\" string"}' \
    -X PUT --data-binary '[{"ref":"smoke:1"}]' "$BASE/tasks"
expect "POST /tasks/done" 200 '{"tasks":[{"ref":"smoke:1","title":"Smoke F"}]}' -X POST "$BASE/tasks/done"
expect "PUT /tasks three for done by index and ref" 200 '{"tasks":[{"title":"Smoke G"},{"ref":"smoke:2","title":"Smoke H"},{"title":"Smoke I"}]}' \
    -X PUT --data-binary '["Smoke G",{"title":"Smoke H","ref":"smoke:2"},"Smoke I"]' "$BASE/tasks"
expect "POST /tasks/done {index:2} removes the third" 200 '{"tasks":[{"title":"Smoke G"},{"ref":"smoke:2","title":"Smoke H"}]}' \
    -X POST --data-binary '{"index":2}' "$BASE/tasks/done"
expect "POST /tasks/done {ref} removes that task" 200 '{"tasks":[{"title":"Smoke G"}]}' \
    -X POST --data-binary '{"ref":"smoke:2"}' "$BASE/tasks/done"
expect "POST /tasks/done {index:5} is 404" 404 '{"error":"no task at index 5, the list has 1"}' \
    -X POST --data-binary '{"index":5}' "$BASE/tasks/done"
expect "POST /tasks/done {ref} unknown is 404" 404 '{"error":"no task with ref smoke:9"}' \
    -X POST --data-binary '{"ref":"smoke:9"}' "$BASE/tasks/done"
expect "POST /tasks/done bad body is 400" 400 '' -X POST --data-binary '[1]' "$BASE/tasks/done"
expect "POST /tasks/done ?source=agent" 200 '{"tasks":[]}' -X POST "$BASE/tasks/done?source=agent"
expect "POST /tasks/done bad source is 400" 400 '{"error":"source must be [a-z0-9._-]"}' -X POST "$BASE/tasks/done?source=Bad%20One"
expect "PUT /tasks ?source=agent" 200 '{"tasks":[{"title":"Smoke F"}]}' -X PUT --data-binary '["Smoke F"]' "$BASE/tasks?source=agent"
expect "POST /tasks/done to empty" 200 '{"tasks":[]}' -X POST "$BASE/tasks/done"
expect "POST /tasks/done on empty stays empty" 200 '{"tasks":[]}' -X POST "$BASE/tasks/done"
expect "PUT /tasks bad JSON" 400 '{"error":"body is not valid JSON"}' -X PUT --data-binary 'not json' "$BASE/tasks"
expect "PUT /tasks non-string item" 400 '{"error":"item 0 is not a string or a {\"title\",\"ref\"} object"}' -X PUT --data-binary '[1,2]' "$BASE/tasks"
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
expect "GET /health with Host main-thing.localhost" 200 "$HEALTH" -H "Host: main-thing.localhost:$PORT" "$BASE/health"
expect "GET /health at http://main-thing.localhost (resolved to loopback)" 200 "$HEALTH" \
    --resolve "main-thing.localhost:$PORT:127.0.0.1" "http://main-thing.localhost:$PORT/health"
expect "GET /health at http://main-thing.localhost (system resolver)" 200 "$HEALTH" "http://main-thing.localhost:$PORT/health"
expect "GET /health with Host main-thing.localhost and no port" 200 "$HEALTH" -H "Host: main-thing.localhost" "$BASE/health"
expect "GET /health with Host localhost:80 on any port" 200 "$HEALTH" -H "Host: localhost:80" "$BASE/health"
expect "GET /health over IPv6" 200 "$HEALTH" -6 "http://[::1]:$PORT/health"
expect "GET /health via 127.0.0.1" 200 "$HEALTH" "http://127.0.0.1:$PORT/health"

expect "GET /hidden at the start" 200 "$original_hidden" "$BASE/hidden"
expect "POST /hide" 200 '{"hidden":true}' -X POST "$BASE/hide"
expect "GET /hidden after hide" 200 '{"hidden":true}' "$BASE/hidden"
expect "POST /hide again stays hidden" 200 '{"hidden":true}' -X POST "$BASE/hide"
expect "POST /show" 200 '{"hidden":false}' -X POST "$BASE/show"
expect "GET /hidden after show" 200 '{"hidden":false}' "$BASE/hidden"
expect "GET /hide" 405 '' "$BASE/hide"
expect "POST /hidden" 405 '' -X POST "$BASE/hidden"

echo "--- main-thing CLI"
same "main-thing hide prints nothing" "" "$(MAIN_THING_PORT=$PORT "$CLI" hide)"
same "main-thing hidden after hide" "true" "$(MAIN_THING_PORT=$PORT "$CLI" hidden)"
same "main-thing show prints nothing" "" "$(MAIN_THING_PORT=$PORT "$CLI" show)"
same "main-thing hidden after show" "false" "$(MAIN_THING_PORT=$PORT "$CLI" hidden)"
same "main-thing health" "$HEALTH" "$(MAIN_THING_PORT=$PORT "$CLI" health)"
same "main-thing set with quotes and an apostrophe" $'She said "go"\nAna\'s memo\nTab\\there' \
    "$(MAIN_THING_PORT=$PORT "$CLI" set 'She said "go"' "Ana's memo" 'Tab\there')"
same "main-thing prints the current task" 'She said "go"' "$(MAIN_THING_PORT=$PORT "$CLI")"
same "main-thing list" $'She said "go"\nAna\'s memo\nTab\\there' "$(MAIN_THING_PORT=$PORT "$CLI" list)"
same "main-thing done" $'Ana\'s memo\nTab\\there' "$(MAIN_THING_PORT=$PORT "$CLI" done)"
same "main-thing done 2 removes the second" "Ana's memo" "$(MAIN_THING_PORT=$PORT "$CLI" done 2)"
same "main-thing done 0 exits 1" "1" "$(MAIN_THING_PORT=$PORT "$CLI" done 0 >/dev/null 2>&1; echo $?)"
same "main-thing done 9 past the end exits 1" "1" "$(MAIN_THING_PORT=$PORT "$CLI" done 9 >/dev/null 2>&1; echo $?)"
same "main-thing set - from stdin" $'Line one\nLine "two"' "$(printf 'Line one\nLine "two"\n' | MAIN_THING_PORT=$PORT "$CLI" set -)"
same "main-thing set --json - with a ref" $'Ref one\nPlain two' "$(printf '[{"title":"Ref one","ref":"smoke:9"},"Plain two"]' | MAIN_THING_PORT=$PORT "$CLI" set --json -)"
same "main-thing list --json prints the objects" '[{"ref":"smoke:9","title":"Ref one"},{"title":"Plain two"}]' "$(MAIN_THING_PORT=$PORT "$CLI" list --json)"
same "main-thing list --json round trips through set --json -" $'Ref one\nPlain two' "$(MAIN_THING_PORT=$PORT "$CLI" list --json | MAIN_THING_PORT=$PORT "$CLI" set --json -)"
same "main-thing set --json without - exits 1" "1" "$(MAIN_THING_PORT=$PORT "$CLI" set --json "A" >/dev/null 2>&1; echo $?)"
same "main-thing unknown command exits 1" "1" "$(MAIN_THING_PORT=$PORT "$CLI" nope >/dev/null 2>&1; echo $?)"
same "main-thing on a dead port says not running" "1" "$(MAIN_THING_PORT=1 "$CLI" >/dev/null 2>&1; echo $?)"
same "main-thing version" "$VERSION" "$(MAIN_THING_PORT=$PORT "$CLI" version)"
same "main-thing port shows the running port" "running on port $PORT" "$(MAIN_THING_PORT=$PORT "$CLI" port | /usr/bin/tail -1)"
same "main-thing help lists every command" "19" "$("$CLI" help | /usr/bin/grep -c '^  main-thing')"
same "main-thing help names the HTTP routes" "9" "$("$CLI" help | /usr/bin/grep -cE '^  (GET|PUT|POST) +/')"

echo "--- hooks"
# A test hook writes its payload to a scratch file. Installed for the run, any existing hook is put back.
CONFIG="${MAIN_THING_CONFIG_DIR:-$HOME/.config/main-thing}"
HOOK="$CONFIG/hooks/list-changed"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/main-thing-smoke.XXXXXX")
mkdir -p "$CONFIG/hooks"
[[ -e "$HOOK" ]] && mv "$HOOK" "$HOOK.smoke-backup"
printf '#!/bin/bash\ncat > "%s/payload.json"\n' "$SCRATCH" > "$HOOK"
chmod 755 "$HOOK"
expect "PUT /tasks ?source=smoke fires the hook" 200 '{"tasks":[{"ref":"smoke:7","title":"Hooked"}]}' \
    -X PUT --data-binary '[{"title":"Hooked","ref":"smoke:7"}]' "$BASE/tasks?source=smoke"
for _ in $(seq 1 20); do [[ -s "$SCRATCH/payload.json" ]] && break; sleep 0.1; done
payload=$(cat "$SCRATCH/payload.json" 2>/dev/null)
same "hook payload event and source" 'list-changed smoke' "$(printf '%s' "$payload" | /usr/bin/sed -E 's/.*"event":"([^"]*)".*"source":"([^"]*)".*/\1 \2/')"
same "hook payload carries the list" '"tasks":[{"ref":"smoke:7","title":"Hooked"}]' "$(printf '%s' "$payload" | /usr/bin/sed -E 's/.*("tasks":\[.*\]).*/\1/')"
same "hook payload time is ISO 8601 UTC" 'ok' "$(printf '%s' "$payload" | /usr/bin/grep -Eq '"at":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z"' && echo ok)"
same "main-thing hooks lists it with exit 0" 'list-changed  ok  last run' "$(MAIN_THING_PORT=$PORT "$CLI" hooks | /usr/bin/head -1 | /usr/bin/cut -c1-26)"
chmod 775 "$HOOK"
expect "group writable hook: the change still lands" 200 '{"tasks":[{"title":"Skipped"}]}' -X PUT --data-binary '["Skipped"]' "$BASE/tasks"
sleep 0.3
same "group writable hook is reported as skipped" 'list-changed  skipped: group or world writable' "$(MAIN_THING_PORT=$PORT "$CLI" hooks | /usr/bin/head -1 | /usr/bin/cut -c1-46)"
rm -f "$HOOK"
[[ -e "$HOOK.smoke-backup" ]] && mv "$HOOK.smoke-backup" "$HOOK"
rm -rf "$SCRATCH"

echo "--- add and links"
expect "POST /tasks appends" 200 '{"tasks":[{"title":"Skipped"},{"title":"Added"}]}' -X POST --data-binary '["Added"]' "$BASE/tasks"
same "main-thing add appends" $'Skipped\nAdded\nOne more' "$(MAIN_THING_PORT=$PORT "$CLI" add "One more")"
same "main-thing add with nothing exits 1" "1" "$(MAIN_THING_PORT=$PORT "$CLI" add >/dev/null 2>&1; echo $?)"
# Fake adapters, installed for the run: "fake" claims https://fake.test/item/<id> (slow/<id> after
# a second) and logs completes; "old" knows only complete, so resolve is an unknown verb (exit 2).
ADAPTERS="$CONFIG/adapters"
LINKS=$(mktemp -d "${TMPDIR:-/tmp}/main-thing-links.XXXXXX")
mkdir -p "$ADAPTERS"
for name in fake old; do [[ -e "$ADAPTERS/$name" ]] && mv "$ADAPTERS/$name" "$ADAPTERS/$name.smoke-backup"; done
cat > "$ADAPTERS/fake" <<'ADAPTER'
#!/bin/bash
case "$1 $2" in
    "resolve https://fake.test/item/"*) printf '{"id":"%s","title":"Fake title %s"}\n' "${2##*/}" "${2##*/}" ;;
    "resolve https://fake.test/slow/"*) sleep 1; printf '{"id":"%s","title":"Slow title"}\n' "${2##*/}" ;;
    "resolve "*) exit 3 ;;
    "complete "*) echo "$2" >> "SCRATCH/completed" ;;
    *) exit 2 ;;
esac
ADAPTER
/usr/bin/sed -i '' "s|SCRATCH|$LINKS|" "$ADAPTERS/fake"
printf '#!/bin/bash\n[[ "$1" == complete ]] || exit 2\n' > "$ADAPTERS/old"
chmod 755 "$ADAPTERS/fake" "$ADAPTERS/old"

# wait_for <name> <exact GET /tasks body>: polls for up to 4 s.
wait_for() {
    local got=""
    for _ in $(seq 1 40); do
        got=$(curl -s "$BASE/tasks")
        [[ "$got" == "$2" ]] && break
        sleep 0.1
    done
    same "$1" "$2" "$got"
}
expect "PUT a list to add links to" 200 '{"tasks":[{"title":"Plain"}]}' -X PUT --data-binary '["Plain"]' "$BASE/tasks"
same "main-thing add <link> shows the placeholder at once" $'Plain\nfake.test/…/42' "$(MAIN_THING_PORT=$PORT "$CLI" add https://fake.test/item/42)"
wait_for "the adapter's title and ref land" '{"tasks":[{"title":"Plain"},{"ref":"fake:42","title":"Fake title 42"}]}'
same "main-thing list shows the title only" $'Plain\nFake title 42' "$(MAIN_THING_PORT=$PORT "$CLI" list)"
MAIN_THING_PORT=$PORT "$CLI" add https://nobody.test/some/page >/dev/null
wait_for "an unclaimed link stays as the title, no ref" '{"tasks":[{"title":"Plain"},{"ref":"fake:42","title":"Fake title 42"},{"title":"https://nobody.test/some/page"}]}'
expect "PUT keeps the old link row as it is" 200 '{"tasks":[{"title":"https://nobody.test/some/page"},{"ref":"fake:42","title":"Fake title 42"}]}' \
    -X PUT --data-binary '["https://nobody.test/some/page",{"title":"Fake title 42","ref":"fake:42"}]' "$BASE/tasks"
sleep 0.3
same "the old link is not asked about again" '{"tasks":[{"title":"https://nobody.test/some/page"},{"ref":"fake:42","title":"Fake title 42"}]}' "$(curl -s "$BASE/tasks")"
expect "PUT with a new link: the placeholder in the reply" 200 '{"tasks":[{"title":"fake.test/…/7"},{"ref":"fake:42","title":"Fake title 42"}]}' \
    -X PUT --data-binary '["https://fake.test/item/7",{"title":"Fake title 42","ref":"fake:42"}]' "$BASE/tasks"
wait_for "a link in a PUT resolves too" '{"tasks":[{"ref":"fake:7","title":"Fake title 7"},{"ref":"fake:42","title":"Fake title 42"}]}'
expect "a link already on the list as a ref" 200 '' -X POST --data-binary '["https://fake.test/item/7"]' "$BASE/tasks"
wait_for "a second copy of a resolved link stays as typed" '{"tasks":[{"ref":"fake:7","title":"Fake title 7"},{"ref":"fake:42","title":"Fake title 42"},{"title":"https://fake.test/item/7"}]}'
expect "a slow link" 200 '{"tasks":[{"title":"fake.test/…/9"}]}' -X PUT --data-binary '["https://fake.test/slow/9"]' "$BASE/tasks"
expect "renamed before the answer" 200 '{"tasks":[{"title":"My own title"}]}' -X PUT --data-binary '["My own title"]' "$BASE/tasks"
sleep 1.5
same "the late answer does not clobber the rename" '{"tasks":[{"title":"My own title"}]}' "$(curl -s "$BASE/tasks")"
expect "a slow link removed before the answer" 200 '{"tasks":[{"title":"fake.test/…/10"}]}' -X PUT --data-binary '["https://fake.test/slow/10"]' "$BASE/tasks"
expect "removed" 200 '{"tasks":[]}' -X PUT --data-binary '[]' "$BASE/tasks"
sleep 1.5
same "the late answer does not bring it back" '{"tasks":[]}' "$(curl -s "$BASE/tasks")"
MAIN_THING_PORT=$PORT "$CLI" add https://fake.test/item/55 >/dev/null
wait_for "resolved for the done test" '{"tasks":[{"ref":"fake:55","title":"Fake title 55"}]}'
MAIN_THING_PORT=$PORT "$CLI" done >/dev/null
for _ in $(seq 1 20); do [[ -s "$LINKS/completed" ]] && break; sleep 0.1; done
same "crossing off a resolved task runs <adapter> complete <id>" "55" "$(cat "$LINKS/completed" 2>/dev/null)"
for name in fake old; do
    rm -f "$ADAPTERS/$name"
    [[ -e "$ADAPTERS/$name.smoke-backup" ]] && mv "$ADAPTERS/$name.smoke-backup" "$ADAPTERS/$name"
done
rm -rf "$LINKS"

expect "restore the saved hidden state" 200 "$original_hidden" -X POST "$BASE/$([[ "$original_hidden" == *true* ]] && echo hide || echo show)"
expect "restore the saved list" 200 "$original" -X PUT --data-binary "$original" "$BASE/tasks"

echo
if [[ $fails -eq 0 ]]; then
    echo "smoke: all checks passed"
    exit 0
fi
echo "smoke: $fails check(s) failed"
exit 1
