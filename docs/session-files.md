# Session Files

cctop stores live session state as JSON files in `~/.cctop/sessions/`. The menubar app treats these files as the local source of truth for what to render, while the hook binary updates them as tools emit lifecycle events.

Session files are intentionally local and inspectable. Missing optional fields must be treated as their default values so older files continue to load.

## Identity

### `harness_session_id`

Type: `string`

Default: `null` when omitted.

The exact unsanitized session reference supplied to `cctop-hook`, byte-for-byte.
For integrations that expose a real conversation reference, this preserves it;
OpenCode intentionally continues to supply its process-scoped synthetic reference
until all of its per-session event payloads can be routed consistently. `session_id` is
sanitized to a restricted character set and truncated to 64 characters so it can
safely appear in file names and logs, which makes it a lossy projection of the
hook reference; `harness_session_id` preserves the original value for
identity derivation. The hook stamps it after a matching event loads the record,
so records created by pre-field hooks gain it in place. A different conversation
may replace a PID-keyed record only through `SessionStart`-driven rotation.

### Action identity

External control surfaces (Stream Deck entries in `display-state.json`,
`cctop://focus?sid=...`) identify each currently visible focus target with an
opaque derived token:
`s-` followed by 32 hex characters (a 128-bit truncated SHA-256 over a
runtime routing tuple, computed by `SessionIdentityPolicy.actionID`).

The tuple includes:

- the session source;
- `harness_session_id`, or the legacy sanitized `session_id` when absent; and
- process-generation identity (`pid` plus `pid_start_time`) when available, or
  the existing row identity for records without process metadata.

Including process generation keeps two visible processes that host the same
conversation one-to-one with their panel rows and Stream Deck slots. A resumed
conversation can therefore receive a different action id in a different process.

Consumers must treat the token as opaque. It deliberately reveals nothing about
how the client keys its sessions (PID-shared or not), and nothing recovers a
PID or session id from it. Do not reproduce the derivation outside cctop; read
the published values. Action identity is intentionally separate from cctop's
internal dedup/grouping keys, which may evolve independently.

Action ids are live runtime routing identifiers, not durable session identity.
Their derivation may evolve, so never persist one as a preference key. Consume
the current published value, as the Stream Deck plugin does. Durable per-session
preferences require a separate canonical identity design and are outside this
contract.

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

Clients that can identify internal helper sessions should set `is_subagent: true` in their hook payloads. For Codex sessions, cctop decodes the structured `threads.source` value from Codex's local thread database: `SessionSource::SubAgent(...)` and `SessionSource::Internal(...)` are hidden, while `cli` and `vscode` remain user-visible even if the legacy diagnostic `thread_source` says `subagent`. `thread_spawn_edges` corroborates topology but is not the primary classifier, because review and guardian helpers may have no edge. Missing, malformed, unknown, or contradictory source evidence fails open and is counted in the session-load diagnostics.

Older cctop versions may have persisted both `is_subagent = true` and `hidden = true` from `thread_source` alone. cctop clears that sticky pair only when structured source proves `cli` or `vscode`, the edge schema is readable and has no spawn edge for the thread, and no independent memory/title auto-hide rule applies.
