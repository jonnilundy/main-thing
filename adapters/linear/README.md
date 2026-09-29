# Linear adapter

Paste a Linear issue link into Main Thing and the task gets the issue's title. Cross the task off and the issue moves to Done in [Linear](https://linear.app).

- `linear resolve <url>` claims `https://linear.app/<workspace>/issue/<ID>/...`, asks the Linear API for the issue, and prints `{"id":"ENG-123","title":"..."}`. The task gets the ref `linear:ENG-123`. Any other link: exit 3, not mine.
- `linear complete <id>` finds the issue's team, picks the team's completed state with the lowest position (usually Done), and moves the issue there. An issue that is already completed is left as it is.
- `linear check` asks Linear who owns the key and prints "Signed in as <name>". The Check button in Settings runs it.

## Set up

The Linear adapter ships inside Main Thing.

1. Create a personal API key in Linear: Settings, Security & access, Personal API keys ([open it](https://linear.app/settings/account/security)).
2. In Main Thing, open Settings, Adapters. Under Linear, turn on Enable, paste the key in API key and click Save.
3. Click Check. It shows "Signed in as <your name>" when the key works, or Linear's error.

The key is stored in your login Keychain (service `com.jonnilundy.mainthing.adapter.linear`, account `LINEAR_API_KEY`). Main Thing passes it to the adapter as `LINEAR_API_KEY` for each run. The adapter sends it to curl on stdin, never on a command line, and never prints it.

### The env file fallback

Before the adapter was built in, it read `~/.config/main-thing/linear.env`. That still works: while no key is saved in Settings, the adapter reads the file.

```sh
cat > ~/.config/main-thing/linear.env <<'KEY'
LINEAR_API_KEY=op://vault/item/field
KEY
chmod 600 ~/.config/main-thing/linear.env
```

A value written as a 1Password reference (`op://vault/item/field`) goes through `op run`, so no secret sits in the file. A plain key works too. Once a key is saved in Settings, the file is not read.

Without a key, a Linear link fails with a message that says where to add one, and the link stays as the task's title.

## Use

```sh
main-thing add https://linear.app/acme/issue/ENG-123/fix-login
main-thing list            # Fix login
main-thing done            # ENG-123 is Done in Linear
```

Pasting the link in the notch's New task field works the same way.

## Check

```sh
main-thing adapters        # linear (built in), its last run and exit code
main-thing logs            # every resolve and complete, with its exit code
# Run the script by hand with the env file fallback, the same call the app makes:
/Applications/MainThing.app/Contents/Resources/adapters/linear check
```

It needs `/usr/bin/jq` and `/usr/bin/curl`, which ship with macOS 15 and later.
