# Linear adapter

Paste a Linear issue link into Main Thing and the task gets the issue's title. Cross the task off and the issue moves to Done in [Linear](https://linear.app).

- `linear resolve <url>` claims `https://linear.app/<workspace>/issue/<ID>/...`, asks the Linear API for the issue, and prints `{"id":"ENG-123","title":"..."}`. The task gets the ref `linear:ENG-123`. Any other link: exit 3, not mine.
- `linear complete <id>` finds the issue's team, picks the team's completed state with the lowest position (usually Done), and moves the issue there. An issue that is already completed is left as it is.

## Install

```sh
mkdir -p ~/.config/main-thing/adapters
ln -s "$PWD/adapters/linear/linear" ~/.config/main-thing/adapters/linear
main-thing adapters        # shows it as installed and whether it may run
```

## Configure

Create a personal API key in Linear (Settings, Security & access, Personal API keys) and put it in `~/.config/main-thing/linear.env`:

```sh
cat > ~/.config/main-thing/linear.env <<'KEY'
LINEAR_API_KEY=your-api-key
KEY
chmod 600 ~/.config/main-thing/linear.env
```

Better: store the key in 1Password and write the reference instead (`LINEAR_API_KEY=op://vault/item/field`). The adapter then runs itself through `op run`, so no secret sits in the file. The key goes to curl on stdin, never on a command line, and is never printed.

Without the file, a Linear link fails with a message that names the file, and the link stays as the task's title.

## Use

```sh
main-thing add https://linear.app/acme/issue/ENG-123/fix-login
main-thing list            # Fix login
main-thing done            # ENG-123 is Done in Linear
```

Pasting the link in the notch's New task field works the same way.

## Check

```sh
~/.config/main-thing/adapters/linear resolve https://linear.app/acme/issue/ENG-123 </dev/null   # the call the app makes
echo '{}' | ~/.config/main-thing/adapters/linear complete ENG-123                                # moves the issue to Done
main-thing logs            # every resolve and complete, with its exit code
```

It needs `/usr/bin/jq` and `/usr/bin/curl`, which ship with macOS 15 and later.
