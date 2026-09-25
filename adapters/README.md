# Writing an adapter

An adapter tells another tool that a task was completed in Main Thing. Main Thing does not know
about Open Brain, Linear, Things or your own scripts. It knows one thing: a task can carry a `ref`
of the form `<adapter>:<id>`. When that task is completed, Main Thing runs the executable at
`~/.config/mainthing/adapters/<adapter>` with `complete <id>`. Everything else is the adapter's
business.

The adapters in this folder each have their own README. Open Brain: [openbrain/README.md](openbrain/README.md).

## The contract

- The file: `~/.config/mainthing/adapters/<name>`. The name is `[a-z0-9-]+` and matches the part
  of the ref before the colon. A symlink to a file elsewhere is fine; the target is what is judged.
- The call: `<adapter> complete <id>`, where `<id>` is the part of the ref after the first colon.
  Other verbs may come later. An adapter should reject verbs it does not know with exit 2.
- Stdin: the event payload as JSON, for example

  ```json
  {"at":"2026-09-25T18:00:28.535Z","event":"task-completed","source":"cli",
   "task":{"ref":"openbrain:md7abc","title":"Write the memo"},
   "tasks":[{"title":"Review the plan"}]}
  ```

  Reading it is optional. The id on the command line is enough for most adapters.
- Exit 0 means synced. Anything else, or no exit within 10 seconds, counts as a failure. Main Thing
  logs the exit code, the duration and the first 2 KB of stderr, shows "sync failed: `<name>`" in
  the open notch until the next successful run of that adapter, and does not retry.
- Run rules: the file must be a regular file owned by you, executable by you, and not writable by
  group or others (`chmod 755` or `700`). Otherwise Main Thing skips it and logs why.
- Environment: your login environment as the app saw it at launch, with `/opt/homebrew/bin`,
  `/usr/local/bin` and `~/.local/bin` added to `PATH`. Started from Login Items that is a small
  PATH, so add the folders your tools live in at the top of the script.
- Adapters run one at a time, in event order, off the main thread. The API call that completed the
  task returns at once; it never waits for an adapter.
- Secrets: never put them in the script. Read them from a file in `~/.config/mainthing/` with
  mode 600, or from your password manager at run time.

## Template

```sh
#!/bin/sh
# ~/.config/mainthing/adapters/mytool: "mytool complete <id>" marks <id> done in My Tool.
set -eu
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
[ "${1:-}" = "complete" ] && [ -n "${2:-}" ] || { echo "usage: mytool complete <id>" >&2; exit 2; }
id="$2"
cat >/dev/null                                   # the payload, not needed here
exec mytool-cli tasks close "$id"                # exit 0 on success, anything else is a failure
```

## Install

Keep the script in your own repo or dotfiles and link it in:

```sh
mkdir -p ~/.config/mainthing/adapters
chmod 755 mytool
ln -s "$PWD/mytool" ~/.config/mainthing/adapters/mytool
mainthing adapters        # lists what is installed and whether each one may run
```

Then give tasks refs:

```sh
printf '[{"title":"Write the memo","ref":"mytool:4821"}]' | mainthing set --json -
```

## Debug

```sh
mainthing adapters                                              # installed, may it run, last exit and stderr
echo '{}' | ~/.config/mainthing/adapters/mytool complete <id>   # run it by hand, same call the app makes
mainthing logs                                                  # every run with its exit code
curl -s mainthing.localhost/status                              # the same as mainthing adapters, as JSON
```

A "skip" line in the log names the run rule that failed. A "killed after 10000 ms" line means the
adapter hung; make it fail fast instead. If an adapter needs a tool that is not on the app's PATH,
add the folder at the top of the script rather than relying on your shell profile.
