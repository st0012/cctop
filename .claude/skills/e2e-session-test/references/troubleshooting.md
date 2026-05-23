# Troubleshooting the e2e session test

Read this when a step fails. It maps symptoms to causes and explains the design
choices behind the happy path.

## No new session appears after launching the agent (step 2/3)

| Symptom | Cause | Fix |
|---|---|---|
| Terminal window opens, agent prints "command not found" | The terminal ran the agent with a minimal `PATH` (no `~/.local/bin`). | Run via a login shell — `zsh -lc <agent>`. The launcher does this. |
| Agent starts but no `~/.cctop/sessions/<pid>.json` | Agent is stalled at a folder-trust prompt and hasn't fired its session hook. | Launch in a directory the user already trusts (a repo they work in), not `$HOME`. |
| Window opens but agent never starts | The terminal's "run a command" flag differs from Ghostty's `-e`. | Adjust the launch line in `launch-cli-session.sh` for your terminal. |
| Session file exists but status never changes | The hook ran once but later events aren't reaching cctop. | Inspect `~/.cctop/logs/<session>.log` — SHIM vs HOOK entries show where the chain broke. |

Per-session logs live in `~/.cctop/logs/`. Each line is
`{timestamp} {SHIM|HOOK} {event} {project}:{id} {detail}`. SHIM-but-no-HOOK means
the hook binary didn't start; no log at all means the agent isn't firing hooks.

## The panel won't open (step 4)

`open cctop://toggle` is deliberately the only supported programmatic path. The
alternatives were tried and rejected:

- **Clicking the menu-bar icon via screen automation** is refused — when an agent
  drives the screen, the OS reports the desktop shell as frontmost and blocks the
  click on it.
- **Sending the global toggle hotkey** works for a human but, posted
  synthetically, needs the Accessibility permission granted to the posting process.
- **Scripting a keystroke via the OS automation bridge** triggers a consent prompt
  that blocks and times out.

The `cctop://` URL scheme needs none of these permissions, so it's what the skill
uses. If `open cctop://toggle` does nothing:

- Confirm a cctop build that registers the scheme is running. Older builds predate
  it. `osascript -e 'id of app "cctop"'` should resolve, and the build should be
  the one from the PR that added `CFBundleURLTypes` for `cctop`.
- If several cctop bundles exist on disk, `open` may route the URL to a stale one.
  Target the running build explicitly:
  `open -a /path/to/CctopMenubar.app cctop://toggle`.

## Why not drive a desktop agent's GUI to create the session?

If the coding agent is the same desktop app that hosts the agent running this test,
two things break:

1. **You can't see it.** Screen-capture tooling excludes the host app's own window
   (so the agent never captures its own conversation), so screenshots show empty
   desktop where that window is.
2. **You can't verify input.** With the window invisible, a blindly-typed message
   might land in the wrong place — including back into the test agent's own session.

A CLI agent in a separate terminal window has neither problem: it's a real session,
created with one shell command, fully visible, and verified by the session file
rather than by sight. That's why the skill standardizes on it.

## Cleaning up

Close the terminal windows you spawned (each hosts a real agent session that will
otherwise keep showing in the panel). Remove temp screenshots. A quick check:

```bash
.claude/skills/e2e-session-test/scripts/cctop-sessions.sh   # should be back to baseline-ish
```
