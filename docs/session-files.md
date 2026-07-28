# Session Files

cctop stores live session state as JSON files in `~/.cctop/sessions/`. The menubar app treats these files as the local source of truth for what to render, while the hook binary updates them as tools emit lifecycle events.

Session files are intentionally local and inspectable. Missing optional fields must be treated as their default values so older files continue to load.

## Identity

### `cctop_session_id`

Type: `string` (lowercase UUID)

Default: absent only on legacy records awaiting migration.

`cctop_session_id` is an opaque identifier generated and owned by cctop for a
logical session. It is random: it is never derived from the client, title,
project path, prompt or transcript content, PID, process generation, terminal,
window, or focus target. When a client supplies a supported durable resume
reference, the value remains stable across cctop and client restarts on the
same machine while cctop's local identity data remains. Otherwise it is
permanent only for that observed record.

For supported resume contracts, cctop keeps a private UUID-only mapping under
`~/.cctop/session-identities/`. Mapping filenames hash the source-scoped client
reference; the raw reference is not copied into this directory. Existing
publishable session JSON files without the field are assigned an ID once and
stamped with the same per-file locking and atomic-write rules as hook updates.
Hidden, finished, cleanup, and history records keep their existing identity
contracts until a current hook or later visible observation needs this field.
Identity mappings intentionally outlive session and history cleanup and are not
automatically pruned in this version.

Deleting cctop's local session and identity data resets this continuity.
Cross-machine sync is not supported.

### `harness_session_id`

Type: `string`

Default: `null` when omitted.

The exact unsanitized session reference supplied to `cctop-hook`, byte-for-byte.
For integrations that expose a real conversation reference, this preserves it;
OpenCode intentionally continues to supply its process-scoped synthetic reference
until all of its per-session event payloads can be routed consistently. `session_id` is
sanitized to a restricted character set and truncated to 64 characters so it can
safely appear in file names and logs, which makes it a lossy projection of the
hook reference; `harness_session_id` preserves the original value for resume
lookup. It is evidence, not cctop identity. The hook stamps it after a matching event loads the record,
so records created by pre-field hooks gain it in place. A different conversation
may replace a PID-keyed record only through `SessionStart`-driven rotation.

### Resume support

| Client | Same cctop ID after reopen/resume | Evidence |
|---|---|---|
| Codex CLI/Desktop | Yes | The client supplies the same UUID conversation reference across process generations. |
| Claude Code/Desktop | Yes when a UUID session reference is available | Claude session/transcript state preserves that UUID across resume. |
| pi | Yes only when `getSessionId()` supplies a real UUID | Synthetic `pi-<pid>` fallback observations remain record-local. |
| OpenCode | Not yet | The plugin intentionally uses a process-scoped synthetic reference until per-event session routing is reliable. |

Every newly observed record still receives a `cctop_session_id`; “not yet” means
cctop cannot promise that a later reopened observation will recover the same
one. References are always source-scoped. cctop never infers that conversations
from different clients contain the same content.

### Stream Deck routing

Display-state schema v2 publishes `cctop_session_id` for every session row.
Stream Deck caches the ID that a key rendered, so a press cannot accidentally
target an unrelated session that moved into the same slot. cctop then resolves
that permanent session ID against the current canonical `SessionManager.sessions`
order and focuses the first currently available target for that session.

Panel, URL focus, DisplayStateWriter, and Stream Deck all consume that canonical
order. The projection never independently sorts, deduplicates, or removes rows,
so slots stay aligned with the panel even when two observations share one
`cctop_session_id`.

This version does not reconcile multiple clients or multiple simultaneous focus
targets. If the same conversation is open in more than one place, observations
may remain separate or several rows may share one ID and resolve to the first
current canonical target. Cross-client equivalence and cross-machine identity
are out of scope. Manual hiding uses `cctop_session_id` as its preference key;
notification grouping, cleanup, history, and other persisted preferences keep
their separate contracts.

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

### Manual hiding

The app's user-triggered **Hide Session** action is separate from the session
file's `hidden` field. After confirmation, cctop stores only the session's opaque
`cctop_session_id` in local preferences; it does not rewrite the hook-owned JSON
or persist the session title, project path, prompts, or tool data.

Manual hiding removes the session from the panel, navigation, notifications, and
Stream Deck output while the full record remains available for lifecycle and
Cleanup tracking. There is no in-app restore. cctop prunes the preference only
after a complete local inventory proves the session record is gone; partial or
unreadable inventories retain it to avoid unexpectedly revealing the session.

### `is_subagent`

Type: `boolean`

Default: `false` when omitted.

When `is_subagent` is `true`, the session file represents a delegated subagent's own workspace rather than the user's top-level conversation. cctop marks these records `hidden` and keeps the file on disk. This is distinct from `active_subagents`, which belongs on the parent user-facing session to show how many delegated agents it currently owns.

Clients that can identify internal helper sessions should set `is_subagent: true` in their hook payloads. For Codex sessions, cctop decodes the structured `threads.source` value from Codex's local thread database: `SessionSource::SubAgent(...)` and `SessionSource::Internal(...)` are hidden, while `cli` and `vscode` remain user-visible even if the legacy diagnostic `thread_source` says `subagent`. `thread_spawn_edges` corroborates topology but is not the primary classifier, because review and guardian helpers may have no edge. Missing, malformed, unknown, or contradictory source evidence fails open and is counted in the session-load diagnostics.

Older cctop versions may have persisted both `is_subagent = true` and `hidden = true` from `thread_source` alone. cctop clears that sticky pair only when structured source proves `cli` or `vscode`, the edge schema is readable and has no spawn edge for the thread, and no independent memory/title auto-hide rule applies.
