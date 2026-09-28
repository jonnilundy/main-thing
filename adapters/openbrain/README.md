# Open Brain adapter

Closes a task in [Open Brain](https://github.com/cpenned/open-brain) when you cross it off in Main Thing. A task with the ref `openbrain:<id>` is completed, Main Thing runs `openbrain complete <id>`, and the adapter runs `ob task done <id>` with the Open Brain CLI.

Paste a link to an Open Brain task, `<your Open Brain web address>/task/<id>`, and Main Thing runs `openbrain resolve <url>`: the adapter reads the title with `ob task get <id> --json`, and the task gets that title and the ref `openbrain:<id>`.

## Install

You need the Open Brain CLI, `ob`, on your machine.

```sh
mkdir -p ~/.config/main-thing/adapters
ln -s "$PWD/adapters/openbrain/openbrain" ~/.config/main-thing/adapters/openbrain
main-thing adapters        # shows it as installed and whether it may run
```

## Configure

Put your Open Brain URL and API key in `~/.config/main-thing/openbrain.env`, one per line:

```sh
cat > ~/.config/main-thing/openbrain.env <<'EOF'
OPEN_BRAIN_API_URL=https://your-deployment.convex.site
OPEN_BRAIN_API_KEY=your-api-key
EOF
chmod 600 ~/.config/main-thing/openbrain.env
```

Optional: values written as 1Password references (`op://vault/item/field`) are resolved at run time through `op run`, so no secret sits in the file.

For pasted links, add the address of your Open Brain web app as a plain value, not a reference. The adapter reads it without `op run`, so links that are not Open Brain's are turned down at once:

```sh
echo 'OPEN_BRAIN_WEB_URL=https://brain.example.com' >> ~/.config/main-thing/openbrain.env
```

Without it, the adapter claims no links. Crossing off still works.

## Use

Give a task the ref `openbrain:<id>`. Task ids come from `ob task list --json`.

```sh
printf '[{"title":"Write the memo","ref":"openbrain:qh75pbc"}]' | main-thing set --json -
```

Or paste the task's link:

```sh
main-thing add https://brain.example.com/task/qh75pbc
```

Cross the task off in the notch, or run `main-thing done`, and it is done in Open Brain too.

## Check

```sh
main-thing adapters                                                  # last run, exit code, stderr
echo '{}' | ~/.config/main-thing/adapters/openbrain complete <id>    # the same call the app makes
~/.config/main-thing/adapters/openbrain resolve <url> </dev/null     # prints {"id","title"}, or exit 3
```
