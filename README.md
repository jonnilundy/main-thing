# NextUp

A small Mac app with no Dock icon. It draws a black notch at the top center of the screen and shows your current task in it. Hover to open it: the current task large, a circle to mark it done, and the next three. A local HTTP API sets the ordered list.

Requires macOS 14 or later. Builds with the Command Line Tools alone (Swift 6.2), no Xcode.

## Install

```sh
scripts/install.sh
```

Builds a release, quits any running copy, copies `NextUp.app` to `~/Applications` and starts it. Launch at Login is in the right click menu on the notch.

## Set the list

The list is an ordered JSON array of titles. Index 0 is the current task.

```sh
# replace the whole list
curl -X PUT http://127.0.0.1:7788/tasks -d '["Write the BAA memo","Review Q3 KPIs"]'

# same, object form
curl -X PUT http://127.0.0.1:7788/tasks -d '{"tasks":["Write the BAA memo","Review Q3 KPIs"]}'

# read it
curl http://127.0.0.1:7788/tasks

# mark the current task done
curl -X POST http://127.0.0.1:7788/tasks/done

# is it up
curl http://127.0.0.1:7788/health
```

Titles are trimmed and blank ones are dropped. Every response is `{"tasks":[...]}`, except `/health` which returns `{"ok":true,"version":"0.1.0"}`.

## API rules

- Loopback only: `127.0.0.1` and `::1`. Nothing else can reach it.
- Any request with an `Origin` header is refused with 403, so a web page cannot change your list.
- `Host` must be `127.0.0.1`, `localhost` or `[::1]`.
- Bad JSON is 400 with a one line reason. Bodies over 64 KB are 413. Unknown routes are 404, wrong methods 405.
- Content-Type does not matter, so a plain `curl -d` works.

Change the port:

```sh
defaults write com.jonnilundy.nextup port 7799
```

Then relaunch. The list is saved to `~/Library/Application Support/NextUp/tasks.json` as a plain JSON array.

## Notch menu

Right click the notch for:

- Launch at Login. Uses the system login items. If macOS asks for approval, the menu says so and opens System Settings.
- Show Tasks File. Reveals `tasks.json` in the Finder.
- Quit NextUp.

## See what it is doing

```sh
log stream --predicate 'subsystem == "com.jonnilundy.nextup"' --style compact
```

Bind errors, refused requests and save errors show up there. If the port is taken, the open notch says "API off on port N".

## Uninstall

Quit from the notch menu, turn Launch at Login off first if it is on, then:

```sh
rm -rf ~/Applications/NextUp.app "~/Library/Application Support/NextUp"
```

## Develop

```sh
swift run nextup-checks      # logic checks: parsing, routing, guards, list keys, hover, geometry
scripts/build-app.sh         # release build into build/NextUp.app
scripts/smoke.sh             # every route with curl against the running app
open build/NextUp.app --args --open   # start with the notch held open, for screenshots
```

Set `NEXTUP_SNAPSHOT_DIR=/some/dir` in the environment to get a PNG of the notch after each change, rendered by the app itself.
