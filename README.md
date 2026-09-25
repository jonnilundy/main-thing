![Main Thing](assets/cover-2026-09.png)

# Main Thing

Main Thing shows the one task you are on right now in a notch at the top of your Mac screen. Hover the notch to see the whole list. Click a task to cross it off. A command and a local API set the list, so your scripts and your AI agent can keep it current.

Requires macOS 15 or later.

## Install

### Download

1. Download `MainThing.dmg` from the [latest release](https://github.com/jonnilundy/main-thing/releases/latest).
2. Open the file and drag Main Thing to the Applications folder.
3. Open Main Thing from Applications. The first time, macOS says it cannot check the app for malicious software, because it is not signed with an Apple developer certificate. Close that message, right click the app, choose Open, and click Open again. If macOS still refuses, open System Settings, go to Privacy & Security, scroll down, and click Open Anyway next to Main Thing. This happens once.

The notch appears at the top of the screen. Right click it for Launch at Login, and for Install Command Line Tool, which puts the `mainthing` command in `~/.local/bin`.

### Build from source

Needs the Command Line Tools, not Xcode.

```sh
xcode-select --install
git clone https://github.com/jonnilundy/main-thing.git
cd main-thing
scripts/install.sh
```

This builds a release, puts `MainThing.app` in `~/Applications`, links the `mainthing` command into `~/.local/bin`, and starts the app. To work on it: `swift run mainthing-checks` runs the logic checks, `scripts/smoke.sh` exercises every route against the running app, `scripts/package.sh` makes the DMG.

## Use

The list is ordered. The first task is the one in the notch. Hover the notch to see all of them. Click a task to cross it off. Click it again in the next moment to keep it. Right click the notch for the menu.

```sh
mainthing set "Write the memo" "Review the plan"   # replace the list
mainthing                                          # print the current task
mainthing list                                     # print the list, one task per line
mainthing done                                     # cross off the current task
mainthing done 2                                   # cross off the second task
mainthing help                                     # every command, the JSON shape, the API
```

A task can carry a ref: the same task's id in another tool, written `<adapter>:<id>`. Refs travel through the JSON forms. `mainthing set --json -` reads `[{"title":"Write the memo","ref":"openbrain:qh75pbc"}]` from stdin, and `mainthing list --json` prints it back.

The list is saved in `~/Library/Application Support/MainThing/tasks.json`.

## HTTP API

The command is a thin wrapper over a local API at `http://mainthing.localhost`. When port 80 is taken, the app uses port 7788 instead, `http://mainthing.localhost:7788`, and `mainthing health` tells you which.

| Request | What it does |
| --- | --- |
| `GET /tasks` | The list |
| `PUT /tasks` | Replace the list. Body: a JSON array of titles or `{"title","ref"}` objects |
| `POST /tasks/done` | Cross off the first task. Body `{"index":N}` or `{"ref":"..."}` picks another |
| `GET /health` | Is the app up, and on which port |

```sh
curl -X PUT mainthing.localhost/tasks -d '["Write the memo","Review the plan"]'
```

Loopback only. A request with an `Origin` header is refused, so a web page cannot change your list. `mainthing help` has the rest.

## Adapters

An adapter closes a task in the tool it came from. A task with the ref `openbrain:qh75pbc` is crossed off, and Main Thing runs `~/.config/mainthing/adapters/openbrain complete qh75pbc`. The adapter does the rest and exits 0 when it worked.

- Open Brain: [adapters/openbrain/README.md](adapters/openbrain/README.md)

To write your own, see [adapters/README.md](adapters/README.md).

## Hooks

A hook runs on every change. Put an executable at `~/.config/mainthing/hooks/task-completed` or `~/.config/mainthing/hooks/list-changed`. It gets the event as JSON on stdin: the time, the event, who made the change, the completed task, and the list after the change. `mainthing hooks` shows what is installed and each one's last run.

## Use it with your agent

Give your agent (Claude Code, Codex, Cursor, anything with a shell) this prompt:

```text
You manage my Main Thing list, the task shown in the notch at the top of my screen.
Run `mainthing help` once for the commands, the JSON shape and the API.
- Keep the list short and ordered, most important first. The first task is what I see all day.
- Read the list before you write it. Change only what we discussed.
- Keep every ref. It ties a task to another tool.
- Never mark a task done unless I say it is done.
```

## Sounds

Crossing a task off plays a short pen scratch. Right click the notch and open Sound to pick another one or turn it off. To add your own, drop audio files (mp3, m4a, wav, aiff, caf) into `~/.config/mainthing/sounds/`. They show up in the menu by file name. The app stays quiet when "Play user interface sound effects" is off in System Settings.

## Troubleshooting

```sh
mainthing health       # is the app up, and on which port
mainthing logs         # what the app is doing: ports, refused requests, hook and adapter runs
mainthing port 7799    # pin another port, then relaunch the app
mainthing port auto    # back to port 80, then 7788
```

Task titles and hook output are redacted in the log as `<private>`. If the port is taken, the open notch says "API off on port N".

An adapter or hook does not run: check its permissions. It must be a regular file (or a link to one) owned by you, executable, and not writable by group or others. `mainthing adapters` says which rule failed. If it needs a tool that is not on the app's PATH, add that folder at the top of the script.

The notch does not open on hover: it only opens over the black shape itself. On a MacBook with a camera housing the shape hangs below the menu bar, under the housing.

## Uninstall

Turn Launch at Login off in the notch menu if it is on, quit from the same menu, then:

```sh
rm -rf /Applications/MainThing.app ~/Applications/MainThing.app "$HOME/Library/Application Support/MainThing" ~/.local/bin/mainthing ~/.config/mainthing
```

## License

MIT, see [LICENSE](LICENSE).
