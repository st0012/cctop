# Session Files

cctop stores live session state as JSON files in `~/.cctop/sessions/`. The menubar app treats these files as the local source of truth for what to render, while the hook binary updates them as tools emit lifecycle events.

Session files are intentionally local and inspectable. Missing optional fields must be treated as their default values so older files continue to load.

## Terminal Focus Metadata

### `terminal.multiplexer`

Type: `object`

Default: `null` when omitted.

When present, `terminal.multiplexer` records pane or surface metadata for a
terminal multiplexer that hosts the session. cctop uses this to jump directly
to the right multiplexer target after focusing the host app.

Supported shapes:

```json
{
  "name": "cmux",
  "socket": "/Users/me/.local/state/cmux/cmux.sock",
  "workspace_id": "B48DBE7E-B98F-48E7-9914-17D7F119BEAA",
  "surface_id": "0BEEE68A-A07D-4225-ACF6-8C973615AA91",
  "binary_path": "/Applications/cmux.app/Contents/Resources/bin/cmux"
}
```

```json
{
  "name": "herdr",
  "socket": "/Users/me/.config/herdr/herdr.sock",
  "pane_id": "w1:p1",
  "binary_path": "/opt/homebrew/bin/herdr"
}
```

```json
{
  "name": "zellij",
  "session_name": "dev",
  "pane_id": "terminal_3",
  "binary_path": "/opt/homebrew/bin/zellij"
}
```

```json
{
  "name": "tmux",
  "socket": "/tmp/tmux-501/default",
  "pane_id": "%3",
  "binary_path": "/opt/homebrew/bin/tmux"
}
```

All multiplexer fields are optional except the values needed for the specific
jump strategy. Older live cmux session files may not have
`terminal.multiplexer`; when the session process is still running and exposes
`CMUX_*` environment variables, the app can recover the cmux workspace and
surface at jump time without rewriting the session file.

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
