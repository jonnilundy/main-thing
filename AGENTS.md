# Main Thing: agent notes

Pointers only. The README "Contributing" section explains the tests, the probes and `render-previews.sh`.

- Work in a worktree, `~/Workbench/code/main-thing-wt/<task>` on `feat/<task>`, never in the main checkout.
- Check before every push: `scripts/check.sh` (build, the checks binary, the adapter scripts; no window, no focus). The pre-push hook runs it. Wire the hook once per clone: `git config core.hooksPath .githooks`. CI runs `scripts/check.sh --probes`.
- Never pipe test or check output before `&&`. The pipe hides the exit code.
- Probes and `scripts/test.sh` take the keyboard focus. Run them on a machine you are not typing on: CI, or the Tart VM `main-thing-box` on iris-agi through `projects/main-thing/vm-run.sh` in the vault. On Jonni's Mac, run only builds and `scripts/check.sh`.
- The VM is shared with Deck. One window run at a time: Deck's `scripts/vm-run.sh` holds the lock folder `~/vm-sync/.vm-gui.lock` on iris-agi while it runs. Wait while it exists (a lock older than 15 minutes is stale).
- Build order in the VM: vm-run.sh syncs without `.build`, so build first (`swift build --product main-thing-checks`, then `swift build --product MainThing`, one product per call), then run a probe or a binary. An unbuilt run failed 24 of 24. The VM bin path is `.build/out/Products/Debug`.
- `scripts/render-previews.sh <dir>` needs Xcode running with the package open.
- Releases: `scripts/release.sh X --publish` (README and the script header). Every public push or release needs Jonni's yes.
- `release.sh --publish` is not resumable. It commits, tags, pushes the tag, creates the GitHub release, then pushes main. If it stops after the tag push, check what is out (`git ls-remote --tags origin`, `gh release view vX`, `appcast.xml` on origin/main) and finish the missing steps by hand. A rerun bumps the build number again.
