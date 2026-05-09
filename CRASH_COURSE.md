# cctop Crash Course

A fast tour of the project as of **v0.15.2** (May 2026). After reading this you should be able to find your way around the code, reason about why each piece exists, and know where to start when changing or debugging things.

For deeper / authoritative docs see `CLAUDE.md` (development rules), `DESIGN.md` (visual system), and `README.md` (user-facing pitch).

---

## 1. What cctop is

cctop is a **macOS menubar app that monitors and lets you jump between AI coding sessions** across multiple coding agents (Claude Code, opencode, pi, Codex CLI). It tells you at a glance which sessions are working, idle, or waiting on you, and clicking a card focuses the right editor / terminal window.

Three top-level constraints shape every decision:

1. **No network. No telemetry.** All state lives in `~/.cctop/` as plain JSON.
2. **Don't break running sessions.** Plugin / hook changes must be backwards-compatible (see the `MIGRATION(...)` markers in code).
3. **Don't touch the user's tool config without consent.** Plugin installs are explicit clicks.

---

## 2. The 60-second mental model

```
Coding agent fires an event ──► tool-specific plugin (thin shim) ──► cctop-hook (Swift CLI)
                                                                          │
                                                                          ▼
                                                                ~/.cctop/sessions/{pid}.json
                                                                          │
                                                                          ▼
                                                            Menubar app (file watcher → SwiftUI)
```

Every supported coding agent normalizes through one binary: **`cctop-hook`**. It's the single source of truth for session-state writes. Plugins exist only to translate per-tool events into the hook's shape.

The menubar app **never writes** session files (except for archiving to history). It just watches the directory and renders.

---

## 3. Repo layout, in priority order

```
menubar/                  Swift/SwiftUI app + cctop-hook CLI (same Xcode project, two targets)
  CctopMenubar/
    Models/               Session, SessionStatus, HookEvent, Config — shared by both targets
    Hook/                 cctop-hook target only (HookMain, HookHandler, HookInput, …)
    Services/             SessionManager (watcher), FocusTerminal (jump logic), PluginManager, …
    Views/                PopupView, SessionCardView, SettingsSection, NotchStatusView, …
    Extensions/           NSScreen+Notch, etc.
  CctopMenubarTests/      XCTest

plugins/
  cctop/                  Claude Code plugin (hooks.json + run-hook.sh shim)
  opencode/               opencode JS plugin (in-process, calls cctop-hook via execFileSync)
  pi/                     pi TS extension (same idea)
  codex/                  Codex CLI: hooks.json + cctop-shim.sh

raycast/                  Raycast extension — reads the same ~/.cctop/sessions/ files
site/                     cctop.app static site (one HTML file, no build)
scripts/                  bundle-macos.sh, sign-and-notarize.sh, generate-appcast.sh, bump-version.sh
.github/workflows/        release.yml, pages.yml
appcast.xml               Sparkle feed (root)
packaging/homebrew-cask.rb
```

Sizes (rough, in lines): Swift ~6.7k, all plugins combined a few hundred. The bulk of complexity is in `Services/` and `Hook/`.

---

## 4. The data model

`menubar/CctopMenubar/Models/Session.swift` — read this file once if you read nothing else.

A `Session` has:

- **Identity.** `pid` is the primary key on disk (file is `{pid}.json`). `pidStartTime` is captured via `sysctl` so PID reuse can be detected. `sessionId` is the agent's own UUID (kept for cross-referencing transcripts).
- **Project context.** `projectPath`, `projectName`, `branch`, optional `workspaceFile` (auto-detected `.code-workspace`).
- **Live status.** `status: SessionStatus`, `lastActivity`, `lastPrompt`, `lastTool` + `lastToolDetail`, `notificationMessage`.
- **Source attribution.** `source` field carries the harness name: `"cc"` (Claude Code, default), `"opencode"`, `"pi"`, `"codex"`. Legacy sessions without it are treated as Claude Code. There's a `MIGRATION(harness_name)` marker for the eventual rename to `harness_name`.
- **Terminal info.** `TerminalInfo` captures the host terminal's bundle ID, TTY, sessionID (iTerm2 GUID / Kitty window ID), remote-control socket (Kitty), and a multiplexer enum (`zellij` / `tmux`). All of this is what makes the "click → focus exact pane" behavior work.
- **Subagents.** `activeSubagents: [SubagentInfo]?` — `nil` means an old plugin that doesn't report; `[]` means none active; an array means an "N agents" badge appears.

`SessionStatus` is a 6-state enum with **forward-compatible decoding** — unknown values map to `.needsAttention` rather than throwing. Status sort order in the UI: waitingPermission → waitingInput / needsAttention → working → compacting → idle.

---

## 5. Status transitions

Centralized in `menubar/CctopMenubar/Models/HookEvent.swift`. There's exactly one transition table:

| Event | New status |
|---|---|
| SessionStart | idle |
| UserPromptSubmit / PreToolUse / PostToolUse / PostToolUseFailure | working |
| Stop, Notification(idle_prompt) | waiting_input |
| PermissionRequest | waiting_permission |
| PreCompact | compacting |
| PostCompact | idle |
| SessionError | needs_attention |
| SubagentStart / SubagentStop | (preserve — only mutates `activeSubagents`) |
| Notification(permission_prompt) | (preserve — `PermissionRequest` already won the race) |
| SessionEnd | (special — stamps `endedAt` so the menubar can archive) |

Each plugin maps its tool's events into these names — e.g. opencode's `tool.execute.before` → `PreToolUse`, pi's `agent_end` → `Stop`. The mapping tables are documented in `CLAUDE.md`.

Two **display-side** adjustments are layered on top in `SessionManager.swift` without touching the file on disk:

- `adjustIdleTimeout` — a session stuck in `waitingInput` for >60 minutes is rendered as `idle` (the user walked away).
- `adjustPermissionStatus` — if a session is `waitingPermission` but a child process started *after* the prompt fired, the user clearly granted permission, so render as `working`. Detected via `proc_listchildpids`.

---

## 6. The hook binary (`cctop-hook`)

Entry point: `menubar/CctopMenubar/Hook/HookMain.swift`. It:

1. Reads JSON from stdin (5s timeout).
2. Parses CLI args — first arg is the hook name; `--harness <name>` overrides the harness for tools (Codex) whose stdin we can't modify.
3. Hands off to `HookHandler.handleHook`.

`HookHandler.swift` is the heart of the project. The flow is:

- **Resolve PID.** `getParentPID()` walks past shell intermediaries (`sh`, `bash`, `zsh`, …) to find the real coding-agent process. This matters because Claude Code's hooks run via `run-hook.sh` and `getppid()` would otherwise return the shell.
- **Acquire a flock** on `{pid}.json.lock` for the entire read-modify-write cycle. Concurrent hooks (e.g. `SubagentStart` + `PreToolUse` firing at the same moment) used to clobber each other before this lock existed.
- **Load or create** the session, with PID-reuse detection (compare stored vs current `pidStartTime`).
- **Apply the transition** from `HookEvent.swift`, plus side effects (clear tool state on prompt submit, record `lastTool`/`lastToolDetail`, etc.).
- **Atomic write** via temp file + `rename(2)`. The temp file name includes the hook process's own PID to avoid concurrent-temp clashes.
- **On `SessionStart`, run cleanup** (outside the lock) — scan all sessions for the same project and remove anything whose PID is dead or has been reused.
- **On `SessionEnd`, stamp `endedAt`** instead of deleting — the menubar app will archive it on the next poll.

`captureTerminalInfo()` is where the "jump to exact pane" magic starts: it reads `TERM_PROGRAM`, `__CFBundleIdentifier`, `ITERM_SESSION_ID`, `KITTY_WINDOW_ID`, `KITTY_LISTEN_ON`, `ZELLIJ_*`, `TMUX_*`, etc., and resolves binaries (kitty, zellij, tmux) by walking `$PATH`. Anything used later for focus must be captured here at hook time, because the menubar app has no access to the agent's environment.

---

## 7. Plugin shapes

| Plugin | Language | Runtime | Mechanism |
|---|---|---|---|
| Claude Code | shell + Swift | hook subprocess | `hooks.json` → `run-hook.sh` → `cctop-hook` |
| opencode | JS | in-process (Bun) | `plugin.js` calls `cctop-hook` via `execFileSync` |
| pi | TS | in-process (Node/jiti) | `cctop.ts` calls `cctop-hook`, **skips** when `ctx.hasUI === false` |
| Codex CLI | shell | hook subprocess | `hooks.json` + `cctop-shim.sh` → `cctop-hook --harness codex` |

Each plugin's job is small: normalize the tool's event into the cctop-hook stdin contract (see `hook-input.schema.json` at the repo root) and call the binary. The opencode plugin also normalizes tool names (lowercase → PascalCase) and arg keys (camelCase → snake_case).

Codex is the most fiddly: it requires the experimental `codex_hooks = true` flag in `~/.codex/config.toml`, doesn't fire `SessionStart` until the first prompt, only emits `Pre/PostToolUse` for its `local_shell` tool, and has no `SessionEnd` (so cleanup falls back to PID liveness).

`PluginManager.swift` and `CodexPluginInstaller.swift` handle one-click install: copy bundled plugin files (in `.app/Contents/Resources/`) into the right tool dir.

---

## 8. The menubar app

Menu of services to know about (all under `menubar/CctopMenubar/Services/`):

- **`SessionManager`** — owns the `[Session]` published array. Watches `~/.cctop/sessions/` via a `DispatchSource` + a 2-second liveness timer. Decodes JSON, separates dead from alive (using PID liveness + `endedAt`), applies display-side adjustments, archives dead sessions to history, sends `UNUserNotification`s for new attention-required transitions. Importantly, only re-publishes when `newSessions != sessions` (the perf fix in PR #95).
- **`FocusTerminal`** — pure-logic `resolveFocusStrategy(session:)` returns a `FocusStrategy` enum (`openWithApp` / `iTerm2` / `kitty` / `ghostty` / `activateByName` / `activateByBundleID` / `openInFinder`). The pure resolution is unit-tested; the AppKit execution is separate. Multiplexer focus is a second strategy layered on top — first focus the app, then the pane.
- **`HistoryManager`** — archives ended sessions to `~/.cctop/history/` and rebuilds "Recent Projects".
- **`PanelCoordinator`** + **`FloatingPanel`** — owns the popup behavior. The panel stays open until the user clicks the menubar icon again (a custom `NSPanel` subclass, not the default popover).
- **`NavigateController`** — handles the global hotkey + numbered-badge overlay (1–9 to jump).
- **`NotchStatusController`** + `NotchStatusPanel` / `NotchStatusView` — on notch MacBooks where the menubar icon hides behind the camera notch, this draws a small clickable pill next to the notch. Detection via `NSScreen.builtin?.hasPhysicalNotch`. Re-evaluated on screen-parameter changes (clamshell mode, monitor connect/disconnect).
- **`SparkleUpdater`** — auto-updates from `appcast.xml`. Critical: the sign-and-notarize script signs Sparkle's framework components **without** the app's entitlements, only the main executable gets entitlements. Apple rejects bundles otherwise.

Views are SwiftUI. Every view has a `#Preview` block with mock data from `Session+Mock.swift` — use Xcode Canvas for visual iteration.

---

## 9. How a session click becomes a focused window

This is one of the highest-leverage flows to understand:

1. Menubar app calls `resolveFocusStrategy(session:)`.
2. Strategy resolution prefers `__CFBundleIdentifier` (unambiguous for VS Code forks) over `TERM_PROGRAM`. It builds a `HostApp` enum (vscode / cursor / windsurf / zed / iterm2 / warp / terminal / ghostty / kitty / unknown).
3. **Editors with a known bundle ID** → `NSWorkspace.open(target, withApplicationAt: bundleID)`. Uses `workspaceFile` if present, else `projectPath`. Never shells out to `code` / `cursor` CLI — those break after Sparkle relaunches with a minimal PATH.
4. **iTerm2** → AppleScript that matches the captured `ITERM_SESSION_ID` GUID against iTerm2's `unique id`, raises the right window/tab/pane. Falls back to plain activation if the GUID is stale.
5. **Kitty** → `kitty @ --to <socket> focus-window --match id:<windowId>`. Requires `allow_remote_control socket-only` + `listen_on` in `kitty.conf`.
6. **Ghostty** → AppleScript matches by working directory (Ghostty 1.3.0+; ambiguous if multiple splits share the same cwd). The latest fix (#102) primes the cwd via OSC 7 first.
7. **Otherwise** → activate by name → activate by bundle ID → open in Finder.
8. **If the session has multiplexer info**, run a second focus on the inner pane (`zellij action focus-pane-id` or `tmux select-window` + `select-pane`).

Knowing this, the answer to "why did my click activate the wrong window?" is almost always: the env vars at hook time didn't capture what we needed (e.g. Ghostty doesn't expose a per-surface env var, hence the cwd fallback).

---

## 10. Filesystem surfaces

```
~/.cctop/
  sessions/{pid}.json       Live session files (atomic writes via rename)
  sessions/{pid}.json.lock  flock target (cleaned with the session)
  history/                  Archived ended sessions
  logs/{session_id}.log     Per-session SHIM + HOOK trace
  logs/_errors.log          Pre-parse errors
  bin/cctop-hook            Optional install location (used by `make install`)
```

Plugin install locations:

```
~/.claude/plugins/cache/cctop/             Claude Code (via `claude plugin install`)
~/.config/opencode/plugins/cctop.js        opencode
~/.pi/agent/extensions/cctop.ts            pi
~/.codex/cctop-shim.sh + ~/.codex/hooks.json + config.toml feature flag
```

---

## 11. Build / test / release

Day-to-day:

```bash
make build      # build both targets + copy plugin assets into Resources/
make test       # XCTest
make lint       # swiftlint --strict (enforced by a pre-edit hook)
make run        # build + open Debug app
make install    # build cctop-hook Release + copy to ~/.cctop/bin/
make all        # lint + build + test (default)
```

Release pipeline (`.github/workflows/release.yml`, triggered by a `v*` tag):

1. Build matrix (arm64 + x86_64) via `scripts/bundle-macos.sh`.
2. Sign + notarize per-arch via `scripts/sign-and-notarize.sh`. Inside-out signing order is critical (dylibs → inner executables → nested bundles → main executable → app). Sparkle's `Autoupdate` lives at `Sparkle.framework/Versions/B/Autoupdate` (no `MacOS/` subdir), which the discovery function specifically searches for.
3. Upload ZIPs to GitHub Releases.
4. `scripts/generate-appcast.sh` updates `appcast.xml` (works around `generate_appcast` not handling multiple ZIPs at the same version by running it on arm64 only, then injecting the x86_64 enclosure with Python).
5. Update Homebrew tap.

**Always use `scripts/bump-version.sh <version>`** to bump versions — it touches the Xcode project's `CURRENT_PROJECT_VERSION`, plugin manifests, the cask, and `site/index.html` together. Don't edit version numbers by hand.

---

## 12. Where to start, by task

| Task | Read this first |
|---|---|
| Add support for a new coding agent | `plugins/opencode/plugin.js` (simplest reference), `Hook/HookInput.swift`, `Hook/HookHandler.swift`, mapping tables in `CLAUDE.md` |
| Add support for a new editor / terminal | `Models/HostApp.swift`, `Services/FocusTerminal.swift`, `Hook/HookHandler.swift::captureTerminalInfo` |
| Add a new status or change a transition | `Models/SessionStatus.swift`, `Models/HookEvent.swift` (transition table), then update display in `Views/SessionStatus+UI.swift` |
| Change a UI thing | The relevant `Views/*.swift` — every view has a `#Preview`. Match `DESIGN.md` |
| Debug "session not appearing" | `~/.cctop/logs/{session_id}.log` — see the diagnosis table in `CLAUDE.md` §"Hook Delivery Debugging" |
| Touch the release pipeline | `scripts/sign-and-notarize.sh` (try `--dry-run`), `scripts/generate-appcast.sh`, `.github/workflows/release.yml` |

---

## 13. Project-specific gotchas worth memorizing

- **Don't break running sessions.** New fields must be optional in `Session` and decoded with `decodeIfPresent`. Renames need a migration plan; see existing `MIGRATION(...)` markers.
- **Session files are keyed by PID, not session_id.** `Session.id` is `pid.map(String.init) ?? sessionId`. Do not assume one PID == one session_id forever (resume creates a new session_id within the same process — handled in `loadOrCreateSession`).
- **The hook subprocess has no TTY.** `findTTY()` walks ancestors to find the controlling terminal. Anything you want to read from the agent's env, read in `captureTerminalInfo()` — the menubar app can't see it later.
- **swiftlint --strict is enforced.** Max line length is 150. There's a Claude Code post-edit hook that auto-runs swiftlint, but `make lint` before commit anyway.
- **Codex and Claude Code don't share a `--harness` story.** Codex stdin is opaque, so the harness comes from `--harness codex` on argv. Other tools set `harness_name` in the JSON. Both paths converge in `HookMain.swift`.
- **`pid_start_time` matters.** Without it, PID reuse across reboots (or fast PID rollover) would silently graft new processes onto stale sessions.
- **The Raycast extension reads the same files.** Any change to the on-disk schema must be reflected in `raycast/src/types.ts` and `raycast/src/sessions.ts`. Raycast also can't shell out to `code`/`cursor` (sandboxed PATH), so it uses `open -a`.
- **The site auto-syncs some things and not others.** Hero version, screenshots, DMG links auto-update. Tool tables, themes, FAQ — manual sync per the table in `CLAUDE.md`. After editing `site/og.html`, **always** re-run `scripts/render-og.sh` and commit `site/og.png` in the same commit (link unfurlers cache the PNG aggressively).

---

That's the project. The single most useful file to internalize is `Hook/HookHandler.swift` — once you understand its locking + transition + side-effect dance, the rest of the codebase is mostly straightforward SwiftUI and tool-specific shims layered around that core.
