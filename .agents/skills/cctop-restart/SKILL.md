---
name: cctop-restart
description: Restart cctop for local development and testing. Use when the user asks to restart, relaunch, run, or prepare the cctop app locally; ensures the current cctop-hook is installed before the menubar app is relaunched and verified.
---

# cctop Restart

When the user asks to restart or relaunch cctop during development, treat it as an end-to-end client refresh:

1. Run `./script/build_and_run.sh --verify` from the repo root when available.
2. If the script is unavailable, run `make restart`.
3. Verify `~/.cctop/bin/cctop-hook` reports or contains the current `Config.hookVersion`.
4. Verify the running `CctopMenubar` process path points at the current worktree/debug app.

Do not use `make run` or `open ...CctopMenubar.app` alone for restart requests; those can leave shims using a stale installed hook.
