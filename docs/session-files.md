# Session Files

cctop stores live session state as JSON files in `~/.cctop/sessions/`. The menubar app treats these files as the local source of truth for what to render, while the hook binary updates them as tools emit lifecycle events.

Session files are intentionally local and inspectable. Missing optional fields must be treated as their default values so older files continue to load.

## Visibility

### `hidden`

Type: `boolean`

Default: `false` when omitted.

When `hidden` is `true`, cctop reads the session file but does not show that session in the active list, does not archive it into Recent Projects, and does not remove it during dead-session cleanup.

Use `hidden` for real session records that should remain on disk for liveness, debugging, or ownership tracking, but should not appear as user-facing work. Current examples include Codex Desktop memory-maintenance sessions and Codex Desktop title-generation helper sessions. Future cases can use the same attribute for background or delegated review sessions, such as Codex sessions summoned by Claude for review.

Do not use file deletion as the hiding signal. Delete a session file only when the session is genuinely obsolete and no longer useful as state.

### `is_subagent`

Type: `boolean`

Default: `false` when omitted.

When `is_subagent` is `true`, the session file represents a delegated subagent's own workspace rather than the user's top-level conversation. cctop marks these records `hidden` and keeps the file on disk. This is distinct from `active_subagents`, which belongs on the parent user-facing session to show how many delegated agents it currently owns.

Clients that can identify subagent-owned sessions should set `is_subagent: true` in their hook payloads. cctop also derives the same marker for Codex sessions whose local thread state reports `thread_source = "subagent"`, so Codex CLI and Codex Desktop subagent threads are hidden even when the hook payload does not include `is_subagent`.
