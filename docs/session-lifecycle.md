# Session Lifecycle

This flow documents how cctop turns a session file into a connection state and then into a UI/cleanup lifecycle.
The desktop path applies to both Claude Desktop and Codex Desktop.

The key split is intentional:

- File presence means cctop has a record to evaluate. It is not itself proof that the session is live.
- `ended_at` is an explicit disconnect signal written by hook events.
- `disconnected_at` is the retention clock for known desktop sessions, including Claude Desktop and Codex Desktop, that have become dormant.
- CLI and ambiguous sessions do not use dormant retention. Once disconnected, they become finished.

```mermaid
flowchart TD
    A["Session file exists"] --> B["Evaluate persisted fields"]
    B --> C{"ended_at present?"}

    C -->|yes| D["Connection state: disconnected"]
    C -->|no| E["Run host-specific liveness check"]

    E --> F{"Host class"}
    F -->|"Known desktop app"| G["Desktop liveness evidence"]
    F -->|"Terminal / CLI"| H["Real process liveness"]
    F -->|"Ambiguous"| I["Conservative process liveness"]

    G --> G1{"Codex Desktop?"}
    G1 -->|yes| G2["Recent hook activity within active window"]
    G1 -->|"Claude Desktop / other desktop app"| G3["Process liveness"]

    H --> J{"Live?"}
    I --> J
    G2 --> J
    G3 --> J

    J -->|yes| K["Connection state: connected"]
    J -->|no| D

    K --> L["Lifecycle: active"]

    D --> M{"Host policy"}
    M -->|"Known desktop app"| N{"disconnected_at present?"}
    M -->|"Terminal / CLI"| O["Lifecycle: finished"]
    M -->|"Ambiguous"| O

    N -->|no| P["Stamp disconnected_at now"]
    P --> Q["Lifecycle: dormant"]
    N -->|yes| R{"Retention expired?"}
    R -->|no| Q
    R -->|yes| S["Lifecycle: finished"]

    Q --> T["Show dormant session"]
    Q --> U["No notifications; neutral display status"]
    S --> V["Desktop GC removes stale .json later"]
    O --> W["Archive and remove .json promptly"]

    V --> X["Never remove .lock files"]
    W --> X
```

## Field Meanings

### `ended_at`

`ended_at` is set when a hook observes `SessionEnd`. It is read before any PID or recency check. If it is present, every host class is considered disconnected.

New activity clears `ended_at` so a resumed session can become connected again.

### `disconnected_at`

`disconnected_at` is only meaningful for known desktop sessions, currently Claude Desktop and Codex Desktop. It starts the dormant retention window.

It can be set in two ways:

- A desktop `SessionEnd` stamps it at the same time as `ended_at`.
- The menubar app stamps it when it first observes a known desktop session as dormant and the field is missing.

CLI sessions do not need `disconnected_at` because disconnected CLI sessions become finished immediately.

## Desktop Host Coverage

Claude Desktop and Codex Desktop both enter the desktop lifecycle path only through trusted bundle IDs:

- Claude Desktop: `com.anthropic.claudefordesktop`
- Codex Desktop: `com.openai.codex`

Once either host is disconnected, the behavior is the same: cctop keeps the session as dormant while `disconnected_at` is inside the retention window, then the slow GC removes the stale `.json` file.

The active liveness evidence is not identical:

- Claude Desktop uses the normal process liveness check unless `ended_at` is present.
- Codex Desktop uses recent hook activity instead of PID liveness, because Codex Desktop can report multiple conversations from a shared host process.

Both hosts still use the same disconnected-state policy after the shared connection step.

## Why This Shape

The connection state is shared across host classes, but host policy differs:

- Desktop disconnection may be temporary because Claude Desktop or Codex Desktop can close or update while conversations still exist inside the app.
- CLI disconnection means the process is gone or the hook explicitly ended the session, so the old archive/remove behavior remains correct.
