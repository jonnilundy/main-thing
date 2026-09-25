# Open Brain adapter

Closes a task in [Open Brain](https://github.com/cpenned/open-brain) when you cross it off in Main Thing. A task with the ref `openbrain:<id>` is completed, Main Thing runs `openbrain complete <id>`, and the adapter runs `ob task done <id>` with the Open Brain CLI.

## Install

You need the Open Brain CLI, `ob`, on your machine.

```sh
mkdir -p ~/.config/mainthing/adapters
ln -s "$PWD/adapters/openbrain/openbrain" ~/.config/mainthing/adapters/openbrain
mainthing adapters        # shows it as installed and whether it may run
```

## Configure

Put your Open Brain URL and API key in `~/.config/mainthing/openbrain.env`, one per line:

```sh
cat > ~/.config/mainthing/openbrain.env <<'EOF'
OPEN_BRAIN_API_URL=https://your-deployment.convex.site
OPEN_BRAIN_API_KEY=your-api-key
EOF
chmod 600 ~/.config/mainthing/openbrain.env
```

Optional: values written as 1Password references (`op://vault/item/field`) are resolved at run time through `op run`, so no secret sits in the file.

## Use

Give a task the ref `openbrain:<id>`. Task ids come from `ob task list --json`.

```sh
printf '[{"title":"Write the memo","ref":"openbrain:qh75pbc"}]' | mainthing set --json -
```

Cross the task off in the notch, or run `mainthing done`, and it is done in Open Brain too.

## Check

```sh
mainthing adapters                                                  # last run, exit code, stderr
echo '{}' | ~/.config/mainthing/adapters/openbrain complete <id>    # the same call the app makes
```
