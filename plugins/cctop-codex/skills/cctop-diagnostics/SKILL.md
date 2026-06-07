---
name: cctop-diagnostics
description: Use when cctop setup fails, sessions are missing or stale, statuses look wrong, Codex hooks need trust, or a non-developer user needs cctop diagnosis without reading files or opening Terminal.
---

# cctop Diagnostics

Help a non-developer get cctop's Codex session tracking working. Do not ask the user to open Terminal, inspect files, paste config contents, or understand hook internals. Run diagnostics yourself, explain outcomes in plain language, and only ask the user for review/confirmation when a change or issue report needs their approval.

## Ground Rules

- Do not print raw `config.toml`, `hooks.json`, session files, logs, prompts, project names, session IDs, usernames, or full local paths.
- Do not spoof Codex hook trust by writing `[hooks.state]` or `trusted_hash` entries.
- Do not use persistent bypass flags such as `--dangerously-bypass-hook-trust`.
- Do not edit Codex or cctop configuration unless the user explicitly confirms the change in the current conversation.
- Treat installed hook files and trusted hook state as separate facts. Installed files alone do not mean hooks will run.

## What To Check

- Codex plugin state in `~/.codex/config.toml`.
- cctop plugin hooks at `~/.cctop/codex-plugin-marketplace/plugins/cctop-codex/hooks/hooks.json`.
- Legacy cctop hooks at `~/.codex/hooks.json` and `~/.codex/cctop-shim.sh`.
- Hook trust entries under `[hooks.state]` in `~/.codex/config.toml`.
- Whether this Codex environment exposes a safe interactive hook-review flow. Do not assume a `codex` executable path.
- cctop session files in `~/.cctop/sessions/` and logs in `~/.cctop/logs/`.

## Workflow

1. Confirm this Codex session has local command/file tools. If it does not, explain that this Codex mode can load the skill but cannot inspect the machine. Do not ask the user to open Terminal; ask them to open a local Codex workspace/session and invoke this skill there. If that is not possible, draft an issue from the facts the user already gave you.

2. Inspect the files yourself. Do not show raw file contents to the user. Summarize only the safe result:

   - installed plugin: current `cctop@cctop`, legacy selector, or missing
   - hooks: plugin hooks present, legacy hooks present, both present, or missing
   - trust: all cctop events trusted, partially trusted, or untrusted
   - trust flow: available in this session or unavailable
   - sessions: Codex session files present or missing
   - stale state: old hook writer metadata or no obvious stale state

3. If hooks are missing, the shim is missing, hooks are disabled, or `cctop-hook` is missing, explain the issue in plain language and propose the smallest safe fix. Ask for confirmation before changing files. Prefer the cctop app's own install/repair path when available.

4. If hooks are installed but untrusted, try the hook-review flow only if this Codex environment provides one:

   - Do not guess Codex executable locations and do not run `codex plugin add`, `codex plugin remove`, or `codex plugin marketplace add`.
   - If your local tools expose an already-valid interactive Codex hook-review UI, open `/hooks`, trust all cctop hook entries, then exit that background review flow.
   - Reinspect `~/.codex/config.toml` after the attempt. Continue only if the trust state changed or you have a clear blocked reason.

5. If hook setup is trusted but sessions still do not appear, inspect archive, hidden, subagent, and stale-session classification before reinstalling hooks. Hook setup is already trusted enough to produce Codex session files, so the next problem is likely cctop visibility or lifecycle filtering.

6. If the trust flow cannot be automated because this Codex environment does not expose it, the UI changed, or Codex refuses the operation, do not make the user debug it manually. Draft a sanitized issue report for the user to review. Omit raw config files, prompts, project names, session IDs, usernames, full local paths, and hook trust hashes. Make clear that they should remove anything they do not want to share before opening an issue.

7. Keep the final answer short: current status, what you fixed or could not fix, and the next user-visible step.
