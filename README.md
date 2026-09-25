![Main Thing](assets/cover.png)

# Main Thing

Main Thing draws a notch at the top of your Mac screen with the one task you are on right now. Hover to open the whole list. Click a task to mark it done. A local API and a small command set the list, so your scripts and your AI agent can keep it current.

Requires macOS 14 or later.

## Install

Build from source with the Command Line Tools. No Xcode needed.

```sh
xcode-select --install        # once, if you do not have the Command Line Tools
git clone https://github.com/jonnilundy/main-thing.git
cd main-thing
scripts/install.sh
```

The install script builds a release, copies `MainThing.app` to `~/Applications`, links the `mainthing` command into `~/.local/bin` and starts the app. Put `~/.local/bin` on your `PATH` if it is not there yet. Right click the notch for Launch at Login.

## Use

The list is ordered. The first task is the one in the notch. Hover over the notch to see all of them; click any one to mark it done. The title is struck through and the row leaves a moment later; click it again in that moment to keep it.

```sh
mainthing set "Write the memo" "Review Q3 KPIs" "Call the vendor"
mainthing                # prints the current task
mainthing list           # one task per line
mainthing done           # marks the current task done
mainthing done 3         # marks the third task done
mainthing health         # is the app up
```

One task per line from stdin:

```sh
printf 'Write the memo\nReview Q3 KPIs\n' | mainthing set -
```

A task can carry a `ref`: the same task's id in another tool, written `<adapter>:<id>`. Refs travel through the JSON forms of `set` and `list`:

```sh
printf '[{"title":"Write the memo","ref":"openbrain:qh75pbc"},"Review Q3 KPIs"]' | mainthing set --json -
mainthing list --json    # [{"ref":"openbrain:qh75pbc","title":"Write the memo"},{"title":"Review Q3 KPIs"}]
```

`set` and `done` take `--source <name>` to say who made the change. Hooks and adapters see it.

### HTTP API

The command is a thin wrapper over a local HTTP API on `http://localhost:7788`. Any client works:

```sh
curl -X PUT http://localhost:7788/tasks -d '["Write the memo","Review Q3 KPIs"]'
curl -X PUT http://localhost:7788/tasks -d '[{"title":"Write the memo","ref":"openbrain:qh75pbc"},"Review Q3 KPIs"]'
curl -X PUT 'http://localhost:7788/tasks?source=agent' -d '{"tasks":["Write the memo"]}'
curl http://localhost:7788/tasks
curl -X POST http://localhost:7788/tasks/done
curl -X POST http://localhost:7788/tasks/done -d '{"index":2}'
curl -X POST http://localhost:7788/tasks/done -d '{"ref":"openbrain:qh75pbc"}'
curl http://localhost:7788/status
curl http://localhost:7788/health
```

- `PUT /tasks` takes a JSON array of strings, of `{"title","ref"}` objects, or a mix, bare or inside `{"tasks":[...]}`. Titles are trimmed and blank ones dropped. A `ref` is `<adapter>:<id>`, adapter name `[a-z0-9-]+`, at most 256 characters, one per list. Anything else is 400 with a one line reason.
- `POST /tasks/done` completes the first task. With a body, `{"index":N}` completes the task at that 0 based index and `{"ref":"<adapter>:<id>"}` the task with that ref. A task that is not there is 404.
- `GET /tasks`, `PUT /tasks` and `POST /tasks/done` answer `{"tasks":[{"title":"A"},{"ref":"openbrain:x","title":"B"}]}`.
- `?source=<name>` on `PUT /tasks` and `POST /tasks/done` names the caller for hooks and adapters. Default `api`.
- `GET /status` lists installed hooks and adapters with their last run.
- `GET /health` returns `{"ok":true,"version":"0.1.0"}`.

Rules at the boundary:

- Loopback only. Nothing off the machine can reach it.
- `Host` must be `localhost`, `mainthing.localhost`, `127.0.0.1` or `[::1]`. Use `localhost` in scripts.
- Any request with an `Origin` header is refused with 403, so a web page cannot change your list.
- Bad JSON is 400. Bodies over 64 KB are 413. Unknown routes are 404, wrong methods 405.
- Content-Type does not matter, so a plain `curl -d` works.

The list is saved to `~/Library/Application Support/MainThing/tasks.json`.

## Adapters

An adapter closes the task in the tool it came from. When you complete a task whose ref is `openbrain:qh75pbc`, Main Thing runs `~/.config/mainthing/adapters/openbrain complete qh75pbc` with the event payload on stdin. The adapter does the rest. Main Thing logs the exit code and shows "sync failed: openbrain" in the open notch until the next run succeeds. It never retries.

### Open Brain

The repo ships an adapter for [Open Brain](https://github.com/cpenned/open-brain). It runs `ob task done <id>` and reads its credentials from 1Password at run time:

```sh
mkdir -p ~/.config/mainthing/adapters
cat > ~/.config/mainthing/openbrain.env <<'EOF'
OPEN_BRAIN_API_URL=https://<deployment>.convex.site
OPEN_BRAIN_API_KEY=op://<vault>/<item>/password
EOF
chmod 600 ~/.config/mainthing/openbrain.env
ln -s "$PWD/adapters/openbrain" ~/.config/mainthing/adapters/openbrain
mainthing adapters
```

### Write your own

An adapter is one executable file named after the adapter, taking `complete <id>`. Exit 0 means synced. The file must be owned by you, executable, and not writable by group or others. The full contract, a template and debugging notes are in [adapters/README.md](adapters/README.md).

## Hooks

A hook runs on every event, not only the ones with a ref. Put an executable at `~/.config/mainthing/hooks/<event>`:

- `task-completed` runs when any task is completed from the notch, the API or the command.
- `list-changed` runs on any change, a completion included.

Each gets the event as JSON on stdin:

```json
{"at":"2026-09-25T18:00:28.535Z","event":"task-completed","source":"notch",
 "task":{"ref":"openbrain:qh75pbc","title":"Write the memo"},
 "tasks":[{"title":"Review Q3 KPIs"}]}
```

`task` is present for `task-completed` only. `tasks` is the list after the change. The same run rules as adapters apply: owned by you, executable, not group or world writable, 10 seconds, no retries. `mainthing hooks` shows what is installed and each one's last run.

## Use it with your agent

Give your AI agent (Claude Code, Codex, Cursor, a Hermes bot, anything with a shell) a prompt like this and it can keep the notch current while you work:

```text
You can manage my Main Thing notch, the task shown at the top of my screen.

Commands, all local:
  mainthing list --json                      the list as JSON, first task is current
  mainthing set --json --source agent -      replace the whole list from a JSON array on stdin
  mainthing done --source agent              complete the current task
  mainthing done 3 --source agent            complete the third task

The JSON shape is an array of {"title": "...", "ref": "..."}. "ref" is optional
and ties a task to another tool as "<adapter>:<id>", for example
"openbrain:qh75pbc" for an Open Brain task id. Always keep the ref when a task
comes from another tool, so completing it in the notch closes it there too.

Rules:
- Keep the list short: the three to six things that matter today, most
  important first. The first item is what I see all day.
- Read the current list before you write it. Never reorder, drop or clear
  tasks I did not ask about; add or edit only what we discussed, and ask
  before any bigger change.
- Titles are short imperatives, under 60 characters, no trailing period.
- Do not run "mainthing done" unless I say the task is done.
```

## Troubleshooting

See what the app is doing:

```sh
/usr/bin/log stream --predicate 'subsystem == "com.jonnilundy.mainthing"' --style compact
```

Bind errors, refused requests, save errors, and every hook or adapter run with its exit code and stderr show up there. `mainthing adapters` and `mainthing hooks` show the last run of each without the log.

Port taken, or you want another one:

```sh
defaults write com.jonnilundy.mainthing port 7799
export MAINTHING_PORT=7799      # for the mainthing command
```

Then relaunch the app. If the port is taken, the open notch says "API off on port N".

An adapter or hook does not run: check its permissions. It must be a regular file (or a link to one) owned by you, executable, and not writable by group or others. `mainthing adapters` says which rule failed. If it needs a tool that is not on the app's PATH, add that folder at the top of the script.

The notch does not open on hover: it only opens over the black shape itself. On a MacBook with a camera housing the shape hangs below the menu bar, under the housing.

The open card is as wide as its longest task, between 420 points and 640 points or half the screen. It grows down to fit every task, up to 60 percent of the screen height; past that the list scrolls inside it.

## Uninstall

Turn Launch at Login off in the notch menu if it is on, quit from the same menu, then:

```sh
rm -rf ~/Applications/MainThing.app "$HOME/Library/Application Support/MainThing" ~/.local/bin/mainthing ~/.config/mainthing
```

## Develop

```sh
swift run mainthing-checks   # logic checks: list keys, refs, routing, events, run rules, hover, geometry
scripts/build-app.sh         # release build into build/MainThing.app
scripts/smoke.sh             # every route with curl and the mainthing command, against the running app
open build/MainThing.app --args --open   # start with the notch held open, for screenshots
```

Set `MAINTHING_SNAPSHOT_DIR=/some/dir` in the environment to get a PNG of the notch after each change, rendered by the app itself. The bundle version comes from `MainThingVersion` in `Sources/MainThingCore/Version.swift`.

A second copy for tests, with no notch and its own files, next to the one you use:

```sh
MAINTHING_HEADLESS=1 MAINTHING_PORT=7799 MAINTHING_TASKS_FILE=/tmp/mt/tasks.json MAINTHING_CONFIG_DIR=/tmp/mt/config \
    build/MainThing.app/Contents/MacOS/MainThing &
MAINTHING_PORT=7799 scripts/smoke.sh
```

## License

MIT, see [LICENSE](LICENSE).
