#!/bin/bash
# The built-in adapter scripts (adapters/linear/linear, adapters/openbrain/openbrain) against a
# fake Linear and Open Brain server on localhost, with a fake `op`. No real service, no real key,
# no real config: HOME and the config folder are throwaway folders.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/main-thing-adapters.XXXXXX")"
SERVER=""
trap '[[ -n "$SERVER" ]] && { kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; }; rm -rf "$TMP"' EXIT
fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
same() { if [[ "$2" == "$3" ]]; then pass "$1 -> $3"; else fail "$1: got [$3], wanted [$2]"; fi; }
has() { if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1: [$3] has no [$2]"; fi; }
hasnt() { if [[ "$3" != *"$2"* ]]; then pass "$1"; else fail "$1: [$3] has [$2]"; fi; }

GOOD="test-key-$RANDOM$RANDOM"
mkdir -p "$TMP/home/.local/bin" "$TMP/config"
# A fake 1Password CLI: `op run --env-file <file> -- <cmd...>` puts the file in the environment
# with every op:// reference replaced by the test key, and notes that it ran.
cat > "$TMP/home/.local/bin/op" <<OP
#!/bin/bash
echo run >> "$TMP/op-ran"
[[ "\$1" == run && "\$2" == --env-file && "\$4" == -- ]] || exit 9
while IFS='=' read -r k v; do
    [[ -z "\$k" ]] && continue
    [[ "\$v" == op://* ]] && v="$GOOD"
    export "\$k=\$v"
done < "\$3"
shift 4
exec "\$@"
OP
chmod 755 "$TMP/home/.local/bin/op"

# The fake servers: POST /graphql is Linear, /v1/... is Open Brain. Each request is logged.
cat > "$TMP/server.py" <<'PY'
import json, sys, http.server
good, log, portfile = sys.argv[1], sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def handle_any(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        auth = self.headers.get("Authorization", "")
        with open(log, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "auth": auth in (good, "Bearer " + good), "body": body, "client": self.headers.get("X-Client", "")}) + "\n")
        if self.path == "/graphql":
            if auth != good:
                return self.reply(400, {"errors": [{"message": "Authentication required, not authenticated"}]})
            q = json.loads(body)["query"]
            if "viewer" in q: return self.reply(200, {"data": {"viewer": {"name": "Test User", "email": "t@example.test"}}})
            if "issueUpdate" in q: return self.reply(200, {"data": {"issueUpdate": {"success": True}}})
            if "issue(" in q:
                return self.reply(200, {"data": {"issue": {"id": "uuid-1", "identifier": "ENG-1", "title": "Fake issue",
                    "state": {"type": "started"}, "team": {"states": {"nodes": [{"id": "s-done", "name": "Done", "position": 1}]}}}}})
            return self.reply(400, {"errors": [{"message": "unknown query"}]})
        if self.path.startswith("/v1/"):
            if auth != "Bearer " + good:
                return self.reply(401, {"error": {"code": "unauthorized", "message": "Invalid API key"}})
            if self.command == "GET" and self.path.startswith("/v1/tasks"): return self.reply(200, {"tasks": []})
            if self.command == "PATCH" and self.path.startswith("/v1/tasks/"): return self.reply(200, {"id": self.path.rsplit("/", 1)[1], "status": "done"})
        return self.reply(404, {"error": {"message": "not found"}})
    do_GET = do_POST = do_PATCH = handle_any
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_address[1]))
s.serve_forever()
PY
/usr/bin/python3 "$TMP/server.py" "$GOOD" "$TMP/requests" "$TMP/port" & SERVER=$!
for _ in $(seq 1 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
PORT="$(cat "$TMP/port" 2>/dev/null)"
[[ -n "$PORT" ]] || { echo "FAIL the fake server did not start"; exit 1; }
LINEAR="$ROOT/adapters/linear/linear"
OB="$ROOT/adapters/openbrain/openbrain"

# run <script> <args...>: a clean environment like the app's, plus whatever is in EXTRA.
# Sets OUT, ERR and CODE.
EXTRA=()
run() {
    OUT="$(env -i HOME="$TMP/home" PATH=/usr/bin:/bin MAIN_THING_CONFIG_DIR="$TMP/config" LINEAR_API_URL="http://127.0.0.1:$PORT/graphql" \
        ${EXTRA[@]+"${EXTRA[@]}"} "$@" </dev/null 2>"$TMP/stderr")"
    CODE=$?
    ERR="$(cat "$TMP/stderr")"
}
last_request() { /usr/bin/tail -1 "$TMP/requests"; }

echo "--- linear"
EXTRA=(LINEAR_API_KEY="$GOOD")
run "$LINEAR" check
same "check with the key in the environment" "0 Signed in as Test User (t@example.test)" "$CODE $OUT"
has "the key went in the header" '"auth": true' "$(last_request)"
run "$LINEAR" resolve https://linear.app/acme/issue/eng-1/fake
same "resolve with the key in the environment" '0 {"id":"ENG-1","title":"Fake issue"}' "$CODE $OUT"
run "$LINEAR" complete ENG-1
same "complete with the key in the environment" "0" "$CODE"
has "complete sent the mutation" 'issueUpdate' "$(last_request)"
run "$LINEAR" resolve https://example.com/issue/ENG-1
same "resolve of another link is not mine" "3" "$CODE"
run "$LINEAR" nope
same "an unknown verb is exit 2" "2" "$CODE"

EXTRA=(LINEAR_API_KEY="wrong-key")
run "$LINEAR" check
same "check with a wrong key fails" "1" "$CODE"
has "and says why in plain words" "linear: Linear API: Authentication required" "$ERR"
hasnt "no key in the output" "wrong-key" "$OUT $ERR"

EXTRA=()
run "$LINEAR" check
same "check with no key and no env file fails" "1" "$CODE"
has "and says where to put it" "Add it in Main Thing Settings, Adapters" "$ERR"

printf 'LINEAR_API_KEY=%s\n' "$GOOD" > "$TMP/config/linear.env"
run "$LINEAR" check
same "a plain env file still works (the fallback)" "0 Signed in as Test User (t@example.test)" "$CODE $OUT"

printf 'LINEAR_API_KEY=op://Vault/Linear/credential\n' > "$TMP/config/linear.env"
rm -f "$TMP/op-ran"
run "$LINEAR" check
same "an env file with op:// goes through op run" "0 Signed in as Test User (t@example.test) run" "$CODE $OUT $(cat "$TMP/op-ran" 2>/dev/null)"
run "$LINEAR" complete ENG-1
same "complete through op run (the hand set up of before)" "0" "$CODE"

rm -f "$TMP/op-ran"
EXTRA=(LINEAR_API_KEY="$GOOD")
run "$LINEAR" check
same "a key in the environment skips the env file and op" "0 no op" "$CODE $([[ -e "$TMP/op-ran" ]] && echo op ran || echo no op)"
rm -f "$TMP/config/linear.env"

echo "--- openbrain"
URL="http://127.0.0.1:$PORT"
EXTRA=(OPEN_BRAIN_API_URL="$URL/" OPEN_BRAIN_API_KEY="$GOOD")
run "$OB" check
same "check with both in the environment" "0 Connected to 127.0.0.1:$PORT" "$CODE $OUT"
has "check is a read of one task" '"method": "GET", "path": "/v1/tasks?limit=1", "auth": true' "$(last_request)"
run "$OB" complete qh75pbc
same "complete with both in the environment" "0" "$CODE"
has "complete is a PATCH to done" '"method": "PATCH", "path": "/v1/tasks/qh75pbc", "auth": true, "body": "{\"status\":\"done\"}", "client": "main-thing"' "$(last_request)"
run "$OB" complete '../keys'
same "an id with a slash is refused before any request" "1" "$CODE"
run "$OB" nope
same "an unknown verb is exit 2" "2" "$CODE"

EXTRA=(OPEN_BRAIN_API_URL="$URL/v1" OPEN_BRAIN_API_KEY="wrong-key")
run "$OB" check
same "check with a wrong key fails" "1" "$CODE"
has "and gives the API's message" "openbrain: Open Brain API: Invalid API key (HTTP 401)" "$ERR"
hasnt "no key in the output" "wrong-key" "$OUT $ERR"

EXTRA=(OPEN_BRAIN_API_URL="$URL")
run "$OB" check
same "no key and no env file fails" "1" "$CODE"
has "and says what is missing" "no API key" "$ERR"

printf 'OPEN_BRAIN_API_URL=%s\nOPEN_BRAIN_API_KEY=op://Vault/Open Brain/credential\n' "$URL" > "$TMP/config/openbrain.env"
rm -f "$TMP/op-ran"
EXTRA=()
run "$OB" complete md7abc
same "an env file with op:// goes through op run" "0 run" "$CODE $(cat "$TMP/op-ran" 2>/dev/null)"
has "and reaches the API" '"path": "/v1/tasks/md7abc", "auth": true' "$(last_request)"
EXTRA=(OPEN_BRAIN_API_URL="$URL")
rm -f "$TMP/op-ran"
run "$OB" check
same "only the URL set: the env file fills in, through op" "0 run" "$CODE $(cat "$TMP/op-ran" 2>/dev/null)"
rm -f "$TMP/op-ran"
EXTRA=(OPEN_BRAIN_API_URL="$URL" OPEN_BRAIN_API_KEY="$GOOD")
run "$OB" check
same "both set skip the env file and op" "0 no op" "$CODE $([[ -e "$TMP/op-ran" ]] && echo op ran || echo no op)"

echo
if [[ $fails -eq 0 ]]; then
    echo "adapter scripts: all checks passed"
    exit 0
fi
echo "adapter scripts: $fails check(s) failed"
exit 1
