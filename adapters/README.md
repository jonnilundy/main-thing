# Writing an adapter

An adapter connects Main Thing to another tool. Main Thing does not know about Open Brain, Linear,
Things or your own scripts. It knows two things: a task can carry a `ref` of the form
`<adapter>:<id>`, and an adapter answers two verbs. When a task with a ref is completed, Main Thing
runs the executable at `~/.config/main-thing/adapters/<adapter>` with `complete <id>`. When a new
task is exactly one link, Main Thing asks the adapters with `resolve <url>` which one it belongs to
and what its title is. Everything else is the adapter's business.

The adapters in this folder each have their own README. Open Brain: [openbrain/README.md](openbrain/README.md).
Linear: [linear/README.md](linear/README.md).

## The contract

- The file: `~/.config/main-thing/adapters/<name>`. The name is `[a-z0-9-]+` and matches the part
  of the ref before the colon. A symlink to a file elsewhere is fine; the target is what is judged.
- The call: `<adapter> complete <id>`, where `<id>` is the part of the ref after the first colon.
  An adapter should reject verbs it does not know with exit 2. Other verbs may come later.
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
- Secrets: never put them in the script. Read them from a file in `~/.config/main-thing/` with
  mode 600, or from your password manager at run time.

## Resolve: a pasted link becomes a task

When a new task's text is exactly one `http` or `https` link, from the add field, `main-thing add`,
`main-thing set` or the API, Main Thing adds it at once with a short dim placeholder (the host and
the last part of the path) and asks the installed adapters about it, one at a time in name order:

```sh
<adapter> resolve <url>
```

- Exit 0 with one JSON object on stdout claims the link: `{"id":"ENG-123","title":"Fix login"}`.
  The task gets that title and the ref `<adapter>:<id>`, so crossing it off runs
  `<adapter> complete <id>`. Other fields in the object are ignored.
- Exit 3 means "not mine": the next adapter is asked. Exit 2, an unknown verb, counts the same, so
  an adapter that only knows `complete` needs no change.
- Anything else, or no answer within 5 seconds, is a failure. It is logged, and the next adapter
  is asked.
- Stdin is empty. The same run rules, environment and PATH as `complete` apply.
- Decide "not mine" before you touch the network or your password manager. Every link goes to
  every adapter until one claims it.

When no adapter claims the link, the link stays as the title. If the task is renamed or removed
before the answer comes, the answer is dropped. Resolve runs show in `main-thing logs` only; a
"not mine" is not a failure, so `main-thing adapters` and "sync failed" stay about `complete`.

## Template

```sh
#!/bin/sh
# ~/.config/main-thing/adapters/mytool
#   mytool complete <id>   marks <id> done in My Tool
#   mytool resolve <url>   claims https://mytool.example/t/<id>, prints {"id","title"}
set -eu
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
case "${1:-}" in
    complete)
        [ -n "${2:-}" ] || { echo "usage: mytool complete <id>" >&2; exit 2; }
        cat >/dev/null                           # the payload, not needed here
        exec mytool-cli tasks close "$2"         # exit 0 on success, anything else is a failure
        ;;
    resolve)
        case "${2:-}" in
            https://mytool.example/t/*) id="${2##*/}" ;;
            *) exit 3 ;;                         # not mine
        esac
        title="$(mytool-cli tasks show "$id" --field title)"
        /usr/bin/jq -cn --arg id "$id" --arg title "$title" '{id: $id, title: $title}'
        ;;
    *) echo "usage: mytool complete <id> | mytool resolve <url>" >&2; exit 2 ;;
esac
```

`/usr/bin/jq` ships with macOS 15 and later.

## Install

Keep the script in your own repo or dotfiles and link it in:

```sh
mkdir -p ~/.config/main-thing/adapters
chmod 755 mytool
ln -s "$PWD/mytool" ~/.config/main-thing/adapters/mytool
main-thing adapters        # lists what is installed and whether each one may run
```

Then give tasks refs:

```sh
printf '[{"title":"Write the memo","ref":"mytool:4821"}]' | main-thing set --json -
```

## Debug

```sh
main-thing adapters                                              # installed, may it run, last exit and stderr
echo '{}' | ~/.config/main-thing/adapters/mytool complete <id>   # run it by hand, same call the app makes
~/.config/main-thing/adapters/mytool resolve <url> </dev/null    # the resolve call; echo $? for 0 or 3
main-thing logs                                                  # every run with its exit code
curl -s main-thing.localhost/status                              # the same as main-thing adapters, as JSON
```

A "skip" line in the log names the run rule that failed. A "killed after 10000 ms" line means the
adapter hung; make it fail fast instead. If an adapter needs a tool that is not on the app's PATH,
add the folder at the top of the script rather than relying on your shell profile.
