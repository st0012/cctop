---
name: e2e-session-test
description: >-
  Use when smoke-testing cctop end to end — verifying a real coding-agent session
  is tracked and shows in the panel. Trigger on "smoke test sessions", "verify
  session tracking", "test the hook pipeline", "check cctop picks up a
  claude/codex/opencode/pi session", or "run the e2e test", even without the word
  "skill". Creates a real CLI agent session in a terminal, confirms cctop tracks
  it, opens the panel programmatically, and captures screenshot proof.
---

# cctop end-to-end session test

Verify a real session flows all the way through:

```
agent in a terminal → cctop hooks → ~/.cctop/sessions/<pid>.json → panel card
```

A good smoke test after touching hooks, the session schema, or the panel.

## Capabilities, not tools

Harness-agnostic — it needs three generic capabilities. Use your environment's
equivalent; don't assume a specific tool:

- **run shell commands**
- **capture a screenshot** of the screen (or fall back to the `screencapture` CLI)
- **view an image** you captured

## Create the session with a CLI agent in a terminal

Drive a CLI agent (`claude` / `codex` / `opencode` / `pi`) in a terminal window —
it's a real session and one shell command starts it. Don't try to puppet a
*desktop* agent's GUI: if it's the app hosting you, screen capture hides its window
and you can't confirm input landed (see `references/troubleshooting.md`). Requires a
cctop build with the `cctop://` URL scheme (ships with this skill).

## Steps (run from the repo root)

```bash
# 1. Baseline — note the PIDs
.claude/skills/e2e-session-test/scripts/cctop-sessions.sh

# 2. Create a session — opens a terminal running the agent, waits for it to register
.claude/skills/e2e-session-test/scripts/launch-cli-session.sh claude ~/projects/cctop

# 3. Verify — a new PID entry with the right source (cc/codex/opencode/pi) appears
.claude/skills/e2e-session-test/scripts/cctop-sessions.sh

# 4. Summon the panel
open cctop://toggle
```

Then **capture a screenshot** and confirm the new session's card is in the panel
(right status, source, project). Run `open cctop://toggle` again to close it — a
clean closed/open pair if you want before/after proof. For a shareable record,
write a small HTML log embedding the screenshots.

Two details the launcher handles, because they otherwise make this fail silently: a
**login shell** (so the agent's `PATH`, e.g. `~/.local/bin`, resolves) and a
**trusted directory** (so the agent doesn't stall at a folder-trust prompt).
`open cctop://toggle` is used instead of a menu-bar click or hotkey because those
need extra OS permissions under automation.

## PASS

- New tracked session within ~5s, correct `source`.
- `open cctop://toggle` opens **and** closes the panel.
- A screenshot shows the card.

On failure, grab the relevant `~/.cctop/logs/<session>.log` entry and see
`references/troubleshooting.md`.
