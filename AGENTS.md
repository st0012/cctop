# AGENTS.md - Development Guide for cctop

## Scope and Sources

cctop is a macOS menu bar app that monitors AI coding sessions and jumps to them.

Use this file for rules that apply to most cctop work. Use these sources for detailed decisions:

- Read [PRODUCT.md](PRODUCT.md) for product intent, feature fit, UX principles, and user-facing language.
- Read [DESIGN.md](DESIGN.md) for visual design rules.
- Read [docs/session-files.md](docs/session-files.md) for session identity, visibility, and focus-routing contracts.
- Read [docs/session-lifecycle.md](docs/session-lifecycle.md) for lifecycle, persistence, archive, and cleanup rules.
- Read [site/README.md](site/README.md) for website deployment and synchronization rules.
- Read [video/framework.md](video/framework.md) for the video build, quality verification, and publication workflow.

Keep canonical repository guidance in this file. Pointer files, such as `CLAUDE.md`, must point to this file instead of copying it.

## Required Development Rules

- Do not change the user's tool configuration without explicit consent. This includes plugins, hooks, and settings files.
- Do not make a compatibility break that requires running sessions to restart before they can reconnect.
- New features can remain unavailable to an existing session until that session restarts.
- Treat `~/.cctop/sessions/*.json`, cctop logs, and client state as debugging evidence. A UI screenshot is only a symptom.
- Keep app liveness, client liveness, visibility, archive state, hidden state, subagent state, and hook provenance separate.
- If a shared source changes, update all owners in the same change. Shared sources include schemas, hook versions, install paths, and release tooling.
- For every version change, run `scripts/bump-version.sh <version>`. Do not edit version values separately.
- Preserve canonical identity and order in `SessionManager.userSessions`. Derive `SessionData` only at the final presentation or direct-action boundary. A direct row action must use the exact `SessionData` value that the row shows.
- Keep Stream Deck downstream of the app. It reads `~/.cctop/display-state.json` and must not recreate session policy.

## Driver Workflow

- Start each independent change from the latest fetched `origin/master` in an isolated worktree.
- For a stacked child, start from the exact approved parent head and target the parent branch.
- Until GitHub retargets the child after the parent merges, keep the parent branch as the target.
- For every PR-capable cctop task, the chief must use `$cctop-chief-workflow` to assign one visible Codex driver.
- The visible driver must create and verify a persistent goal before repository or GitHub inspection.
- An internal subagent does not replace the visible driver.
- The active driver owns edits, tests, commits, PR publication, CI fixes, and the approval loop.
- If team support is available, pair each non-trivial driver with one read-only navigator for the full task.
- Keep exactly one active writer for a branch or PR.
- Make the smallest change that satisfies the approved behavior.
- Keep unrelated lifecycle, UI, release, and documentation work separate.
- Do not add flags, configuration, abstractions, or explicit default values without a current need.
- Before the developer approves the uncommitted result, do not commit, push, or open a PR.
- For a UI change, show a screenshot or rendered preview before publication approval.
- Treat no response as no approval. After explicit approval, continue without a second routine approval.
- Do not commit scratch scripts, investigation pages, screenshots, or generated debugging files. Commit only intentional project assets.
- After you open or update a PR, invoke `$pr-until-approved`. Keep the approval loop with the active driver.

## GitHub and PR Rules

- Never post PR replies, comments, issue comments, or reviews. Leave all GitHub text to the developer.
- Independent review must verify that each eligible bot-authored thread is fixed, deliberately dismissed, or outdated.
- Before reporting the PR ready, the active driver must resolve each verified thread. This requirement includes unknown bot authors.
- Require explicit developer authorization before you resolve a human-authored thread.
- Before final PR closeout, verify the title, body, changed files, current head, CI, and review-thread state.
- Use `$pull-request-description` for PR text structure. Do not copy general PR-writing rules into this file.

## Code Review Rules

- **Consequential defects:** Report only reachable defects that cause material harm or materially wrong visible behavior.
- Exclude style concerns, theoretical races, speculative hardening, mechanical CI results, and missing tests without a concrete regression.
- **Scope and proportionality:** Review the approved behavior instead of an adjacent redesign.
- If the smallest safe correction needs extra machinery, require only the necessary part.
- **Evidence and safe path:** Name the trigger, affected users or data, concrete harm, and smallest safe correction.
- Use `$implementation-review-gate` before publication of a non-trivial change.

## Runtime and Test Safety

Before any runtime action, use `$cctop-runtime-lane`. Request the private lease, wait for an explicit grant, and verify ownership.

Runtime actions include:

- A cctop app build, run, restart, or termination.
- An Xcode app or test-host run, including snapshot tests.
- A `cctop-hook` installation or replacement.
- A Launch Services change or custom URL test.
- A Computer Use pass against cctop.
- A fixture app or end-to-end test that can publish shared display state.

Use `$cctop-e2e-testing` to define risk-based runtime proof. Use `$cctop-restart` for a local restart request.

- For app, hook, and integration source changes, use `make all` after you obtain the runtime lease.
- For documentation-only changes, run focused documentation verification. Do not run app or test-host work without a relevant risk.
- For hook-contract changes, run `make contract`. The schema, fixtures, validators, and sources own hook-event inventories.
- If feasible, add a failing regression test before you correct a bug.
- If a test replaces a persisted input, isolate every writable companion store that can react to that input.
- Never combine a fixture session inventory with real developer preferences or files.
- A test must not prune, migrate, or rewrite real developer state.
- For an affected public UI image, run `make snapshots` under the runtime lease and inspect the output.

Before reporting runtime readiness:

1. Build and restart from the active driver's exact worktree.
2. Install that worktree's `cctop-hook`.
3. Verify the running app path.
4. Verify the installed hook version and binary hash against the worktree build.
5. Report the app path, hook version, and identity evidence.

If the work starts or stops the development app, leave the verified debug app running. Stop it only after a developer request or blocked relaunch.

## Architecture and Agent Integration Map

The Swift menu bar app and `cctop-hook` share models. The hook receives client events and writes local session JSON. The app classifies those records and publishes the visible projection.

All supported agent integrations call `cctop-hook`. Do not add a second session-state path inside a plugin.

| Agent or host | Source and file key | Design rule |
| --- | --- | --- |
| Claude Code | `source: "cc"`, PID-keyed file | Process generation controls CLI liveness. Finished sessions enter Recent Projects before removal. |
| Claude Desktop | `source: "cc"`, PID-keyed file | Trust `com.anthropic.claudefordesktop` only with `cc`. Use desktop archive and retention evidence. |
| Codex CLI and Desktop | `source: "codex"`, session-ID-keyed file | Use the shared Codex lifecycle. Persisted desktop bundle metadata is not host evidence. |
| opencode | `source: "opencode"`, PID-keyed file | Explicit source wins over inherited desktop bundle metadata. Process liveness controls lifecycle. |
| pi | `source: "pi"`, PID-keyed file | Skip non-interactive sessions. Explicit source wins over inherited desktop bundle metadata. |

Keep hook-event and client-event mappings out of this file. Update the contract sources and run `make contract` instead.

## Session Debugging

For wrong source, grouping, status, visibility, or cleanup behavior, inspect the session JSON before you change display logic.

- If `created_by_hook_version` is missing or null, treat the original writer as unknown.
- Inspect for an outdated or pre-metadata hook. Never infer or backfill the original writer.
- A current `last_written_by_hook_version` proves only the most recent writer. It does not identify the original writer.
- If provenance is current, inspect the resolved source, event delivery, liveness, visibility, archive state, and lifecycle separately.
- Trust desktop bundle metadata only for the supported source and host pairing in the integration map.
- Apply lifecycle and hook corrections to all supported clients. If evidence proves a client-specific fault, limit the correction to that client.

Use `~/.cctop/logs/<session-id>.log` and `~/.cctop/logs/_errors.log` to locate hook-delivery failures. Use the session documents for the persistence and lifecycle contracts.

## Focused Workflow Triggers

- For video story or storyboard work, use `$video-storyboard` and [video/framework.md](video/framework.md).
- After approval of a video render, use `$video-assets`. Do not upload media through ad hoc release commands.
- For a release request, use `$release`. That skill owns release verification, signing, appcast, and publication.
- For website changes, follow [site/README.md](site/README.md).
- For SwiftUI debugging, use `$swiftui-debugging` and follow [DESIGN.md](DESIGN.md).
- For build and test commands, use the `Makefile` instead of duplicating its command inventory here.
