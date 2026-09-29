# Open Brain adapter

Closes a task in [Open Brain](https://github.com/cpenned/open-brain) when you cross it off in Main Thing. A task with the ref `openbrain:<id>` is completed, Main Thing runs `openbrain complete <id>`, and the adapter marks the task done through the Open Brain HTTP API (`PATCH /v1/tasks/<id>` with `{"status":"done"}`), with curl. It does not need the `ob` command.

## Set up

The Open Brain adapter ships inside Main Thing.

1. Make an API key in Open Brain: Settings, API Keys, New API key, with the scopes `tasks:read` and `tasks:write`. The key starts with `obr_`.
2. In Main Thing, open Settings, Adapters. Under Open Brain, turn on Enable, put your deployment in API URL (`https://<deployment>.convex.site`, the address the `ob` command uses), paste the key in API key and click Save.
3. Click Check. It reads one task and shows "Connected to <host>" when the URL and key work, or the API's error.

The key is stored in your login Keychain (service `com.jonnilundy.mainthing.adapter.openbrain`, account `OPEN_BRAIN_API_KEY`), the URL in the app's preferences. Main Thing passes both to the adapter as `OPEN_BRAIN_API_URL` and `OPEN_BRAIN_API_KEY` for each run. The adapter sends the key to curl on stdin, never on a command line, and never prints it.

### The env file fallback

Before the adapter was built in, it read `~/.config/main-thing/openbrain.env`. That still works: while the URL or the key is missing in Settings, the adapter reads the file.

```sh
cat > ~/.config/main-thing/openbrain.env <<'EOF'
OPEN_BRAIN_API_URL=https://your-deployment.convex.site
OPEN_BRAIN_API_KEY=op://vault/item/field
EOF
chmod 600 ~/.config/main-thing/openbrain.env
```

Values written as 1Password references (`op://vault/item/field`) go through `op run`, so no secret sits in the file. Plain values work too. Once both are set in Settings, the file is not read.

## Use

Give a task the ref `openbrain:<id>`. Task ids come from `ob task list --json` or the Open Brain API.

```sh
printf '[{"title":"Write the memo","ref":"openbrain:qh75pbc"}]' | main-thing set --json -
```

Cross the task off in the notch, or run `main-thing done`, and it is done in Open Brain too.

## Check

```sh
main-thing adapters        # openbrain (built in), its last run, exit code, stderr
# Run the script by hand with the env file fallback, the same call the app makes:
/Applications/MainThing.app/Contents/Resources/adapters/openbrain check
```

It needs `/usr/bin/jq` and `/usr/bin/curl`, which ship with macOS 15 and later.
