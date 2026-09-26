#!/bin/bash
# Renders every #Preview in Sources/MainThingApp/Previews.swift to a PNG in the given folder,
# through Xcode's MCP bridge (`xcrun mcpbridge`). No screen, cursor or unlocked session needed.
# Needs Xcode running with this package open. Prints one line per preview: its path.
#
#   scripts/render-previews.sh <dir>
#
# The first run asks you, in Xcode, to approve the agent and this folder.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-}"
if [[ -z "$OUT" ]]; then
    echo "usage: scripts/render-previews.sh <dir>" >&2
    exit 2
fi
# Xcode's headless service when it runs, so the Xcode window is never asked anything and keeps
# its scheme; else the Xcode app itself.
SERVICE="$(/usr/bin/pgrep -f "Xcode Service.app/Contents/MacOS/Xcode Service" | /usr/bin/head -1 || true)"
if [[ -n "$SERVICE" ]]; then
    export MCP_XCODE_PID="$SERVICE"
elif ! /usr/bin/pgrep -xq Xcode; then
    echo "render-previews.sh: Xcode is not running. Open $ROOT/Package.swift in Xcode, then retry." >&2
    exit 1
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# The bridge speaks JSON-RPC over stdio: initialize, notifications/initialized, then tools/call.
# Each preview builds and renders in Xcode; the whole run gets 15 minutes.
exec /usr/bin/perl -e 'alarm 900; exec @ARGV' python3 - "$ROOT" "$OUT" <<'PY'
import json, os, re, select, shutil, subprocess, sys, time

root, out = sys.argv[1], sys.argv[2]
source = os.path.join(root, "Sources/MainThingApp/Previews.swift")
scheme = "MainThingApp"
count = sum(1 for line in open(source) if line.startswith("#Preview("))

def fail(message):
    print("render-previews.sh: " + message, file=sys.stderr)
    sys.exit(1)

try:
    bridge = subprocess.Popen(["xcrun", "mcpbridge"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, text=True, bufsize=1)
except OSError as error:
    fail(f"could not start xcrun mcpbridge: {error}")
next_id = 0

def request(method, params, timeout=60):
    global next_id
    next_id += 1
    bridge.stdin.write(json.dumps({"jsonrpc": "2.0", "id": next_id, "method": method, "params": params}) + "\n")
    bridge.stdin.flush()
    end = time.time() + timeout
    while time.time() < end:
        ready, _, _ = select.select([bridge.stdout], [], [], 1)
        if not ready:
            continue
        line = bridge.stdout.readline()
        if not line:
            fail("the Xcode MCP bridge closed. Is Xcode running with the package open?")
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if message.get("id") == next_id:
            if "error" in message:
                fail(f"{method}: {message['error'].get('message', message['error'])}")
            return message["result"]
    fail(f"{params.get('name', method)}: no answer from Xcode in {timeout}s")

def call(tool, arguments, timeout=60, check=True):
    result = request("tools/call", {"name": tool, "arguments": arguments}, timeout)
    text = "".join(part.get("text", "") for part in result.get("content", []))
    if result.get("isError") and check:
        fail(f"{tool}: {text}")
    return result.get("structuredContent") or {}, text

request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": "render-previews", "version": "1"}})
bridge.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
bridge.stdin.flush()

# Open this package's workspace, or get the identifier of the open one. Listing workspaces
# first would also ask the Xcode window, which can sit on an approval prompt and never answer.
opened, text = call("XcodeOpenWorkspace", {"path": root}, timeout=300, check=False)
if "approved" in text:
    print("render-previews.sh: approve the agent in Xcode, then run again", file=sys.stderr)
    sys.exit(1)
workspace = opened.get("workspaceIdentifier") or fail(f"XcodeOpenWorkspace: {text[:400]}")

# Previews render in the library's own scheme; the scheme that was active comes back after.
schemes, _ = call("XcodeListSchemes", {"workspaceIdentifier": workspace})
previous = schemes.get("activeSchemeName")
if previous != scheme:
    call("XcodeSwitchScheme", {"workspaceIdentifier": workspace, "schemeName": scheme})

relative = os.path.basename(root) + "/Sources/MainThingApp/Previews.swift"
failed = []
try:
    for index in range(count):
        result, text = call("RenderPreview", {
            "sourceFilePath": relative, "previewDefinitionIndexInFile": index,
            "workspaceIdentifier": workspace, "timeout": 300,
        }, timeout=360)
        snapshot = result.get("previewSnapshotPath")
        if not snapshot:
            failed.append(index)
            print(f"render-previews.sh: preview {index} did not render: {text[:400]}", file=sys.stderr)
            continue
        name = re.sub(r"[^a-z0-9]+", "-", result.get("displayName", f"preview {index}").lower()).strip("-")
        path = os.path.join(out, f"{index + 1:02d}-{name}.png")
        shutil.copyfile(snapshot, path)
        print(path)
finally:
    if previous and previous != scheme:
        call("XcodeSwitchScheme", {"workspaceIdentifier": workspace, "schemeName": previous})
    bridge.stdin.close()
    bridge.terminate()

if failed:
    sys.exit(1)
PY
