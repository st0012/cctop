# CLAUDE.md - Development Guide for cctop

## Project Overview

cctop is a macOS menubar app for monitoring AI coding sessions across workspaces. It tracks session status (idle, working, needs attention) via tool-specific plugins and allows jumping to sessions. Works with Claude Code and opencode. Also includes a Raycast extension that reads the same session data.

## MUST FOLLOW: Development Principles

- Do NOT modify the user's tool configuration without explicit consent (e.g. installing plugins, editing hooks or settings files)
- Do NOT make breaking changes that require users to restart running sessions to reconnect to the app
  - Newly added features being unavailable until restart is acceptable

## Architecture

```
cctop/
├── menubar/           # Swift/SwiftUI app (menubar + hook CLI)
│   ├── CctopMenubar.xcodeproj/
│   ├── CctopMenubar/
│   │   ├── CctopApp.swift         # App entry point
│   │   ├── AppDelegate.swift      # NSStatusItem + FloatingPanel toggle
│   │   ├── FloatingPanel.swift    # NSPanel subclass (stays open)
│   │   ├── Models/                # Session, SessionStatus, HookEvent, Config (shared)
│   │   ├── Views/                 # PopupView, SessionCardView, QuitButton, etc.
│   │   ├── Services/              # SessionManager, FocusTerminal
│   │   └── Hook/                  # cctop-hook CLI target only
│   │       ├── HookMain.swift     # CLI entry point (stdin, args, dispatch)
│   │       ├── HookInput.swift    # Codable struct for Claude Code hook JSON
│   │       ├── HookHandler.swift       # Core logic (transitions, cleanup, PID)
│   │       ├── SessionNameLookup.swift # Session name from transcript/index
│   │       └── HookLogger.swift        # Per-session logging
│   └── CctopMenubarTests/
├── raycast/           # Raycast extension (TypeScript/React)
│   ├── package.json           # Extension manifest (single command)
│   ├── src/
│   │   ├── show-sessions.tsx  # Main list command
│   │   ├── sessions.ts        # Session loading, parsing, grouping
│   │   ├── actions.ts         # Jump-to-session logic
│   │   ├── status-ui.ts       # Status color/label/icon mapping
│   │   └── types.ts           # TypeScript interfaces
│   ├── metadata/              # Store screenshots
│   ├── CHANGELOG.md           # Store changelog
│   └── README.md              # Store README
├── plugins/cctop/     # Claude Code plugin
│   ├── .claude-plugin/plugin.json
│   ├── hooks/hooks.json
│   └── skills/cctop-setup/SKILL.md
├── plugins/opencode/  # opencode plugin (JS, translates events to cctop-hook calls)
│   ├── plugin.js      # Event handler, calls cctop-hook binary
│   └── package.json   # Plugin manifest
├── plugins/pi/        # pi coding agent extension (TS, translates events to cctop-hook calls)
│   └── cctop.ts       # Extension entry point, calls cctop-hook binary
├── scripts/
│   ├── bundle-macos.sh        # Build and bundle .app
│   ├── sign-and-notarize.sh   # Code sign + Apple notarization
│   ├── generate-appcast.sh    # Sparkle appcast (multi-arch)
│   ├── bump-version.sh        # Version bumper (all files incl. site/index.html)
│   └── render-og.sh           # Render site/og.html → site/og.png (1200x630)
├── site/                # Public website (cctop.app)
│   ├── index.html       # Single static page, no build step
│   └── README.md        # Local preview + sync rules
├── .github/workflows/
│   └── pages.yml        # Auto-deploys site/ to GitHub Pages on push to master
├── packaging/
│   └── homebrew-cask.rb  # Homebrew cask template
└── .claude-plugin/
    └── marketplace.json  # For local plugin installation
```

### Swift Menubar App

The macOS menubar app is built with Swift/SwiftUI. It uses a custom `AppDelegate` with `NSStatusItem` and a `FloatingPanel` (NSPanel subclass) that stays open until the user clicks the menubar icon again.

**Location:** `menubar/`

**Build:**
```bash
# Build from command line
xcodebuild build -project menubar/CctopMenubar.xcodeproj -scheme CctopMenubar -configuration Debug -derivedDataPath menubar/build/ CODE_SIGN_IDENTITY="-"

# Run the app
open menubar/build/Build/Products/Debug/CctopMenubar.app

# Run tests
xcodebuild test -project menubar/CctopMenubar.xcodeproj -scheme CctopMenubar -configuration Debug -derivedDataPath menubar/build/
```

**Visual verification:** Open the Xcode project and use SwiftUI Previews (Canvas) for instant visual feedback. All views have `#Preview` blocks with mock data.

**Data flow:** The menubar app reads `~/.cctop/sessions/*.json` files. These are written by `cctop-hook` (Swift CLI), which is called by all plugins (Claude Code hooks, opencode JS plugin, pi TS extension). Both Xcode targets share model code.

### Raycast Extension

A Raycast extension that reads the same `~/.cctop/sessions/*.json` files and provides a searchable session list with filtering, detail pane, and jump-to-session actions.

**Location:** `raycast/`

**Build & Dev:**
```bash
cd raycast && npm install
npm run dev    # Start development mode (hot reload)
npm run build  # Production build
npx ray lint   # Lint (must pass with 0 errors for Store submission)
```

**Key files:**
- `raycast/src/show-sessions.tsx` — Main list command with filtering, sections, detail pane
- `raycast/src/sessions.ts` — Session loading (reads `~/.cctop/sessions/*.json`), parsing, grouping, utilities
- `raycast/src/actions.ts` — Jump-to-session logic (VS Code, Cursor, iTerm2, Warp, etc.)
- `raycast/src/status-ui.ts` — Status color/label/icon mapping
- `raycast/src/types.ts` — `CctopSession` interface matching the Swift `Session` model

**Publishing to the Raycast Store:**

The extension is published via PR to the [raycast/extensions](https://github.com/raycast/extensions) repo. The `raycast/` directory in this repo maps to `extensions/cctop/` in the Store repo.

```bash
# Initial submission
# 1. Fork https://github.com/raycast/extensions
# 2. Copy raycast/ contents into extensions/cctop/
# 3. Open a PR — Raycast team reviews and merges

# Updating the extension
# 1. Make changes in this repo's raycast/ directory
# 2. Copy updated files to your fork's extensions/cctop/
# 3. Update raycast/CHANGELOG.md with a new entry (use {PR_MERGE_DATE} as the date — Raycast fills it in on merge)
# 4. Open a PR to raycast/extensions
```

**Versioning:** Raycast extensions have no `version` field in `package.json` — do not add one. There is only one implicit latest version, auto-updated for all users when a PR merges. Version history is tracked entirely via `raycast/CHANGELOG.md` using the format:
```markdown
## [Descriptive Title] - {PR_MERGE_DATE}

- What changed
```
The `{PR_MERGE_DATE}` placeholder is replaced with the actual date on merge. Each PR to `raycast/extensions` must include a new changelog entry (enforced by CI).

**Store requirements:**
- `npx ray lint` must pass with 0 errors
- `raycast/CHANGELOG.md` must exist with `## [Title] - {PR_MERGE_DATE}` entries
- `raycast/README.md` must exist
- At least one screenshot in `raycast/metadata/` (PNG, 2000x1250)
- `author` in `package.json` must be a registered Raycast username
- Do NOT include a `version` field in `package.json`

**Important notes:**
- Raycast's Node.js environment is sandboxed — `/usr/local/bin` is NOT in PATH. CLI tools like `code`, `cursor` cannot be called directly. Use `execFileSync("open", ["-a", appName, target])` instead.
- The extension polls session files every 2 seconds via `setInterval`.
- `raycast-env.d.ts` is auto-generated by Raycast and gitignored.

### Website (`site/`)

The public site at https://cctop.app lives in `site/index.html` — a single static page with no build step. Pushed to master, `.github/workflows/pages.yml` uploads `site/` as the GitHub Pages artifact and deploys.

**One-time repo settings:**
1. Settings > Pages > Source = "GitHub Actions".
2. Settings > Pages > Custom domain = `cctop.app`. The `site/CNAME` file pins this on every deploy — without it, the artifact upload would clear the custom domain on each run.
3. After the Let's Encrypt cert provisions, check "Enforce HTTPS". `.app` is HSTS preloaded, so HTTPS is mandatory.

**Local preview:**
```bash
python3 -m http.server 8000 --directory site
```

**What the site auto-syncs from the repo (no manual edit needed):**
- Hero badge version — a small `fetch()` to the GitHub releases API overrides the static fallback at page load. The static fallback is bumped by `scripts/bump-version.sh`.
- Screenshots — referenced via `https://raw.githubusercontent.com/st0012/cctop/master/docs/...`, so updating `docs/*.png` or `docs/*.gif` propagates to the site automatically.
- DMG download links — use the `releases/latest/download/...` redirect, so they always point at the newest release.

**What you must manually keep in sync when changing the implementation:**
- README "Supported Tools" table → site `#tools` "Coding agents" cards (name + URL)
- README "Supported Editors & Terminals" tiers → site `#tools` "Editors & terminals" subgroups (the three tiers: targets pane / opens project / activates app)
- Color theme list (`Color+Theme.swift`, README themes table) → site `#themes` cards (name, accent hex swatch, screenshot filename)
- README FAQ → site `#faq` `<details>` entries
- Hero / install / privacy copy if the README's framing changes

`site/README.md` has the same sync table for quick reference when working in the site folder.

**Social preview card (`site/og.html` → `site/og.png`):**

The social preview is a static HTML source rendered to a 1200×630 PNG and committed alongside it. The site's `og:image` meta tag points at `https://cctop.app/og.png`.

**ALWAYS** re-run `scripts/render-og.sh` after editing `site/og.html`, and commit `site/og.png` in the same commit. Otherwise the deployed `og:image` and the source diverge — link unfurlers (Twitter, Slack, Discord) cache OG images aggressively, so a stale PNG can persist for days even after the source change ships.

```bash
scripts/render-og.sh   # writes site/og.png from site/og.html
```

The script uses Chrome headless (auto-detected on macOS, override with `CHROME_BIN=...`). It validates the output is exactly 1200×630 and exits non-zero if rendering fails. The script is also safe to re-run — it always overwrites the existing PNG.

## Supported Agents

| Agent | Supported | Integration | Runtime | Plugin Location | Detection |
|-------|-----------|-------------|---------|-----------------|-----------|
| Claude Code | Yes | Shell hooks → `cctop-hook` CLI | Subprocess (Swift) | `~/.claude/plugins/cache/cctop/` | Plugin dir exists |
| opencode | Yes | JS plugin → `cctop-hook` CLI | Bun | `~/.config/opencode/plugins/cctop.js` | `~/.config/opencode/` exists |
| pi | Yes | TS extension → `cctop-hook` CLI | Node.js (jiti) | `~/.pi/agent/extensions/cctop.ts` | `~/.pi/` exists |
| Codex CLI | Yes | `hooks.json` + shim → `cctop-hook` CLI | Shell (via `$SHELL -lc`) | `~/.codex/hooks.json` + `~/.codex/cctop-shim.sh` | `~/.codex/` exists |
| Aider | No | — | — | — | — |
| Goose | No | — | — | — | — |
| Amp | No | — | — | — | — |

### How each integration works

- **Claude Code**: Fires shell hooks on lifecycle events. A shell shim (`run-hook.sh`) dispatches to `cctop-hook`, a Swift CLI bundled in the app. `cctop-hook` reads JSON from stdin, applies status transitions, and writes `~/.cctop/sessions/{pid}.json`. Installed via `claude plugin install cctop`.
- **opencode**: Runs a JS plugin in-process (Bun). The plugin translates opencode events to `cctop-hook` calls via `execFileSync`. Installed via the app UI (copies bundled plugin to opencode's plugins dir).
- **pi**: Runs a TS extension in-process (Node.js via jiti). The extension translates pi events to `cctop-hook` calls via `execFileSync`. Skips non-interactive sessions (`ctx.hasUI === false`) to avoid tracking background agents. Installed via the app UI (copies bundled extension to pi's extensions dir).
- **Codex CLI**: Uses Codex's lifecycle hooks system (feature flag `[features].hooks` in `~/.codex/config.toml`, default-true). cctop writes a shell shim to `~/.codex/cctop-shim.sh` and merges five hook entries into `~/.codex/hooks.json` (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop). config.toml is only patched when there's something to fix: (a) strip any `codex_hooks` line, which triggers Codex's startup warning whenever loaded; (b) override an explicit `hooks = false` opt-out so the install actually fires. The "Update Available" tile in Settings surfaces any pending patch so the user opts in with a click rather than having cctop edit their config silently. `isInstalled()` treats an unset flag as installed (Codex default) — only an explicit opt-out under `[features]` counts as not installed. Each event fires `$SHELL -lc "~/.codex/cctop-shim.sh <Event>"`, which execs `cctop-hook` with `--harness codex`. **Codex quirks to know about:** interactive `codex` does NOT fire `SessionStart` at cold launch — it fires SessionStart immediately before the first `UserPromptSubmit`, so cctop won't display an interactive codex session until the user submits their first prompt. Tool tracking is limited to shell calls (Codex only emits `PreToolUse`/`PostToolUse` for its `local_shell` tool today). No `SessionEnd` event — dead sessions are cleaned up via PID liveness.

All paths converge at `~/.cctop/sessions/*.json` — the menubar app watches this directory and renders sessions regardless of source. Each tool identifies itself via `harness_name` in the hook input (JSON field for opencode/pi, `--harness` CLI arg for Claude Code and Codex). The session JSON file still uses the `source` key for the harness name (MIGRATION(harness_name) tracks the eventual rename).

## Key Components

### Binaries
- `CctopMenubar.app` - macOS menubar app (Swift/SwiftUI, built via Xcode)
- `cctop-hook` - Hook handler called by all plugins (Swift CLI, Xcode target in same project)
- `plugins/opencode/plugin.js` - opencode plugin (JS, translates events to cctop-hook calls)
- `plugins/pi/cctop.ts` - pi coding agent extension (TS, maps events to cctop-hook calls)
- `plugins/codex/hooks.json` + `plugins/codex/cctop-shim.sh` - Codex CLI plugin (hooks.json template + shell shim)

### Data Flow

All tools use `cctop-hook` as the single entry point for session state management. Each plugin translates tool-specific events into hook calls.

**Claude Code path:**
1. Claude Code fires hooks (SessionStart, UserPromptSubmit, Stop, etc.)
2. `run-hook.sh` (shell shim) dispatches to `cctop-hook` (Swift CLI)
3. `cctop-hook` writes session files to `~/.cctop/sessions/`

**opencode path:**
1. opencode fires plugin events (session.created, chat.message, tool.execute.before, etc.)
2. `plugin.js` translates events to hook calls and invokes `cctop-hook` via `execFileSync`
3. `cctop-hook` writes session files to `~/.cctop/sessions/`

**pi path:**
1. pi fires extension events (session_start, input, tool_execution_start, etc.)
2. `cctop.ts` translates events to hook calls and invokes `cctop-hook` via `execFileSync`
3. `cctop-hook` writes session files to `~/.cctop/sessions/`
4. Non-interactive sessions (`ctx.hasUI === false`) are skipped entirely

**All paths converge:** The menubar app (SessionManager file watcher) reads `~/.cctop/sessions/*.json` and displays live status regardless of source. Sessions include a `source` field identifying the harness (`"cc"` for Claude Code, `"opencode"` for opencode, `"pi"` for pi, `"codex"` for Codex CLI; `nil` for legacy sessions before the harness_name migration).

## Development Commands

```bash
# Build both targets (menubar app + cctop-hook CLI)
make build

# Run all tests
make test

# Lint with swiftlint --strict
make lint

# Build + lint + test (default)
make all

# Build and open the menubar app
make run

# Install cctop-hook to ~/.cctop/bin/ (Release build)
make install

# Clean build artifacts
make clean

# Check a specific session file
cat ~/.cctop/sessions/<pid>.json | jq '.'

# Bump version (updates pbxproj, plugin JSON, cask, etc.)
scripts/bump-version.sh 0.3.0

# Build release .app bundle
scripts/bundle-macos.sh
```

**IMPORTANT:** Always use `scripts/bump-version.sh <version>` to bump versions. Never edit version numbers manually — the script updates all files including `CURRENT_PROJECT_VERSION` in the Xcode project.

### Linting

The project uses [SwiftLint](https://github.com/realm/SwiftLint) in strict mode. Run `make lint` before committing. Common issues:
- **Line length**: Max 150 characters. Break long lines (especially in `Session+Mock.swift` mock arrays).
- A Claude Code hook in `.claude/settings.json` auto-runs swiftlint on every file edit, but always verify with `make lint` before committing.

### Visual Changes
- Use Xcode Previews (Canvas) for instant visual feedback on any SwiftUI view
- All views have `#Preview` blocks with mock data for different states

## Testing the Hooks

```bash
# Manually trigger a hook to create/update a session
echo '{"session_id":"test123","cwd":"/tmp","hook_event_name":"SessionStart"}' | /Applications/cctop.app/Contents/MacOS/cctop-hook SessionStart

# Or use the debug build
echo '{"session_id":"test123","cwd":"/tmp","hook_event_name":"SessionStart"}' | menubar/build/Build/Products/Debug/cctop-hook SessionStart

# Check if session was created
cat ~/.cctop/sessions/test123.json

# Clean up test session
rm ~/.cctop/sessions/test123.json
```

## Testing the opencode Plugin

The opencode plugin (`plugins/opencode/plugin.js`) is installed via the menubar app when the user clicks "Install Plugin" in Settings > Monitored Tools or via the install banner that appears when opencode is detected (`~/.config/opencode/` exists). The bundled plugin is copied to `~/.config/opencode/plugins/cctop.js`.

For local development, you can manually copy your modified plugin to override the installed version:

```bash
# Override the installed plugin with your local changes
cp plugins/opencode/plugin.js ~/.config/opencode/plugins/cctop.js

# Start an opencode session — a session file should appear
ls ~/.cctop/sessions/

# Check the session file includes source: "opencode"
cat ~/.cctop/sessions/*.json | jq '.source'
```

Note: The app only installs the plugin when the user explicitly clicks "Install Plugin" — it will not overwrite your local changes automatically. However, if you click "Install Plugin" again from the UI, it will overwrite with the bundled version.

## Jump-to-Session Behavior

- **VS Code / Cursor (menubar app)**: Uses `NSWorkspace.open` with the editor's bundle ID to focus the project window. Does not shell out to `code`/`cursor` CLI (avoids PATH issues after Sparkle updates). If a `.code-workspace` file is detected in the project directory, it's passed instead of the folder path.
- **VS Code / Cursor (Raycast extension)**: Uses `open -a "Visual Studio Code" <path>` because Raycast's sandboxed Node.js doesn't have `/usr/local/bin` in PATH. The `code` CLI cannot be called directly.
- **Workspace limitation**: cctop detects workspace files by scanning the project directory at session start. If the project folder contains a `.code-workspace` file but you opened the folder directly (not via the workspace file), cctop may incorrectly open the workspace instead of focusing the folder window. VS Code does not expose which mode was used via environment variables or APIs.
- **iTerm2**: Uses AppleScript to match the session's `ITERM_SESSION_ID` GUID against iTerm2's `unique id` property. Raises the correct window (`set index of w to 1`), selects the tab, and focuses the pane. Falls back to generic `app.activate()` if the session ID is missing or stale. Requires macOS Automation permission (prompted on first use via `NSAppleEventsUsageDescription`).
- **Other terminals**: Falls back to `NSRunningApplication.activate()` (activates the app but cannot target a specific window).

## Session Status Logic

6-status model with forward-compatible decoding (unknown statuses map to `.needsAttention`). Transitions are centralized in `HookEvent.swift`. All tools go through `cctop-hook`; each plugin translates its events into hook events (see tables below).

### Claude Code Hook Events

| Hook Event | Status |
|------------|--------|
| SessionStart (startup\|resume\|clear\|compact) | idle (also stores PID for liveness detection) |
| UserPromptSubmit | working |
| PreToolUse | working (sets last_tool/last_tool_detail) |
| PostToolUse | working |
| PostToolUseFailure | working (stores error in notification_message) |
| Stop | waiting_input |
| Notification (idle_prompt) | waiting_input |
| Notification (elicitation_dialog) | waiting_input |
| Notification (permission_prompt) | waiting_permission |
| PermissionRequest | waiting_permission |
| SubagentStart | (no status change — adds to active_subagents) |
| SubagentStop | (no status change — removes from active_subagents) |
| PreCompact | compacting |
| SessionEnd | (removes session file immediately) |

### opencode Plugin Event Mapping

The opencode plugin (`plugin.js`) translates opencode events to cctop-hook calls:

| opencode Event | Hook Event Called |
|------------|--------|
| session.created | SessionStart |
| chat.message | UserPromptSubmit |
| tool.execute.before | PreToolUse |
| tool.execute.after | PostToolUse |
| session.idle | Stop |
| session.status (retry) | SessionError |
| permission.ask | PermissionRequest |
| experimental.session.compacting | PreCompact |
| session.compacted | PostCompact |
| session.updated | (stores session_name locally, passed in subsequent calls) |
| session.deleted / permission.replied | (skipped — handled by liveness check / next event) |

### pi Extension Event Mapping

The pi extension (`cctop.ts`) translates pi events to cctop-hook calls. Non-interactive sessions (`ctx.hasUI === false`) are skipped entirely.

| pi Event | Hook Event Called |
|------------|--------|
| session_start | SessionStart (also checks `ctx.hasUI` to gate all tracking) |
| input | UserPromptSubmit |
| tool_execution_start | PreToolUse |
| tool_execution_end | PostToolUse (or PostToolUseFailure if `isError`) |
| agent_end | Stop |
| session_before_compact | PreCompact |
| session_compact | PostCompact |
| session_switch | SessionStart (updates session_name) |
| session_shutdown | SessionEnd |

### Session File Format

Session files are keyed by PID (`{pid}.json`), not session_id. Each file stores `pid_start_time` (from `sysctl`) to detect PID reuse. Dead sessions are detected via PID liveness + start time checking. Each session includes `"source": "<harness>"` (`"cc"`, `"opencode"`, `"pi"`, `"codex"`). Legacy sessions without the field are treated as Claude Code.

The `active_subagents` field tracks currently running subagents (Agent tool). It's `nil` for sessions that haven't reported subagent events (old plugin), `[]` when no subagents are active, or an array of `{agent_id, agent_type, started_at}` objects. The menubar app shows a purple badge (e.g. "2 agents") when the count is > 0.

## Notch Status View

On MacBook laptops with a camera notch, the menubar icon is often hidden behind the notch. The notch status view solves this by displaying a small black pill next to the camera notch showing a grid icon + proportional status bar. Clicking the pill toggles the main panel (same as clicking the menubar icon). The panel positions itself under whichever anchor is visible (pill or menubar icon) and clamps to screen bounds.

### Auto-Detection

- **Notch Mac (built-in display):** Shows clickable NotchStatusPanel next to the notch when the menubar icon is occluded
- **Non-notch / external display:** Hides notch panel; menubar icon (44px) is always visible
- Detection uses `NSScreen.builtin?.hasPhysicalNotch` (checks `safeAreaInsets.top > 0`)
- Display changes (clamshell mode, external monitor connect/disconnect) handled via `NSApplication.didChangeScreenParametersNotification`

### Key Files

- `menubar/CctopMenubar/Extensions/NSScreen+Notch.swift` — Notch detection (`hasPhysicalNotch`, `notchSize`, `isBuiltinDisplay`)
- `menubar/CctopMenubar/Views/NotchStatusPanel.swift` — Borderless, non-activating NSPanel (clickable, toggles main panel)
- `menubar/CctopMenubar/Views/NotchStatusView.swift` — SwiftUI pill with grid icon + proportional status bar
- `menubar/CctopMenubar/Services/NotchStatusController.swift` — Panel lifecycle (`showOnScreen`, `update`, `tearDown`)
- `menubar/CctopMenubar/Views/MenubarIconRenderer.swift` — Renders 44px menubar icon (16px icon + 22px status bar)

### Keyboard Shortcuts (Panel)

| Shortcut | Context | Action |
|----------|---------|--------|
| Escape | Normal mode | Reset selection |
| Escape | Navigate mode | Cancel navigate, restore focus |
| Up/Down arrows | Panel open | Navigate sessions |
| Return | Session selected | Jump to session terminal |
| Tab | Panel open | Toggle Active/Recent tab |
| Left/Right arrows | Panel open | Switch to Active/Recent tab |
| 1-9 | Navigate mode | Jump to numbered session |

## Hook Delivery Debugging

All tools go through `cctop-hook`. When sessions stop updating,
use per-session logs in `~/.cctop/logs/` to identify which component failed.

### The Chain

```
Claude Code fires hook -> run-hook.sh (SHIM) -> cctop-hook (HOOK) -> session file -> menubar app
opencode fires event  -> plugin.js (JS)      -> cctop-hook (HOOK) -> session file -> menubar app
pi fires event        -> cctop.ts (TS)       -> cctop-hook (HOOK) -> session file -> menubar app
```

### Log Files

- `~/.cctop/logs/{session_id}.log` — Per-session log with SHIM + HOOK entries
- `~/.cctop/logs/_errors.log` — Pre-parse errors (before session ID is known)

Log files are automatically cleaned up when their session is cleaned up (PID no longer alive).

### Log Format

Each line:

```
{ISO 8601 timestamp} {SHIM|HOOK} {event} {project}:{session_prefix} {details}
```

Examples:
```
2026-02-09T15:12:25Z     SHIM SessionStart cctop:3328c1b0 dispatching
2026-02-09T15:12:25.610Z HOOK SessionStart cctop:3328c1b0 idle -> idle
2026-02-09T15:12:26.100Z HOOK PreToolUse   cctop:517ca7b2 working -> working
```

### Diagnosing Failures

| Symptom in session log | Cause | Fix |
|------------------------|-------|-----|
| No log file for a session | Claude Code not firing hooks | Check `claude plugin list`, restart session |
| SHIM entries but no HOOK entries | cctop-hook binary not starting | Ensure cctop.app is in /Applications/, check paths |
| HOOK entries but session file stale | File write failure | Check disk space, permissions on ~/.cctop/sessions/ |
| HOOK entries present and session file fresh | Menubar file watcher issue | Restart the menubar app |
| Entries stop but session is still running | That Claude Code session stopped firing hooks | Check if session PID is still alive |

### Quick Commands

```bash
# Watch a specific session's events in real time
tail -f ~/.cctop/logs/<session-id>.log

# Show only state-changing transitions (skip working -> working noise)
grep 'HOOK' ~/.cctop/logs/<session-id>.log | grep -v 'working -> working'

# Show all logs across sessions
cat ~/.cctop/logs/*.log | sort | tail -40

# Show only SHIM entries (verify hooks are being dispatched)
grep 'SHIM' ~/.cctop/logs/<session-id>.log

# Check pre-parse errors
cat ~/.cctop/logs/_errors.log
```

## Plugin Debugging (opencode / pi)

Both plugins call `cctop-hook` via `execFileSync`, so per-session logs in `~/.cctop/logs/` work the same as Claude Code. If `cctop-hook` isn't found, calls silently fail. Pi additionally skips non-interactive sessions (`ctx.hasUI === false`) — no session file or log will be created.

| Symptom | Cause | Fix |
|---------|-------|-----|
| No session file appears | Plugin not installed, cctop-hook not found, or (pi only) non-interactive session | Verify plugin: `ls ~/.config/opencode/plugins/cctop.js` or `ls ~/.pi/agent/extensions/cctop.ts`. Verify binary: `ls /Applications/cctop.app/Contents/MacOS/cctop-hook` or `~/.cctop/bin/cctop-hook` |
| No HOOK entries in logs | Plugin calling hook but binary failing | Check `~/.cctop/logs/_errors.log` for parse errors |
| Session file appears but status doesn't update | Plugin event handler error or stale plugin | Check tool console for JS/TS errors; reinstall via Settings > Monitored Tools |

```bash
# Verify source field per session
cat ~/.cctop/sessions/*.json | jq '{project: .project_name, status: .status, source: .source}'
```

## General Debugging Tips

```bash
# Check what Claude Code sends to hooks
grep "hook" ~/.claude/debug/<session-id>.txt | head -20

# List running claude processes and their directories
ps aux | grep -E 'claude|Claude' | grep -v grep

# Check specific process working directory
lsof -p <PID> | grep cwd

# View session file contents
cat ~/.cctop/sessions/*.json | jq '.project_name + " | " + .status'
```

## Release Pipeline

The release is triggered by pushing a version tag (`v*`). The GitHub Actions workflow (`.github/workflows/release.yml`) runs 5 jobs:

1. **Build macOS** (matrix: arm64 + x86_64) — `xcodebuild` archive + `scripts/bundle-macos.sh`
2. **Sign & Notarize** — `scripts/sign-and-notarize.sh` (per-arch)
3. **Create Release** — uploads both ZIPs to GitHub Releases
4. **Update Sparkle Appcast** — `scripts/generate-appcast.sh` updates `appcast.xml` on master
5. **Update Homebrew Tap** — updates the cask formula

### Code Signing Strategy

Sparkle framework components must be signed **without** the app's entitlements. Only the main executable and the `.app` bundle itself get `--entitlements`. Everything else (XPC services, helper apps, framework dylibs, standalone binaries) gets just identity + hardened runtime + timestamp. This is critical for notarization — Apple rejects bundles where XPC services have inappropriate entitlements like `com.apple.security.automation.apple-events`.

The signing order is inside-out: dylibs first, then inner executables, then nested bundles (depth-first), then main executable, then the app bundle.

**Key pitfall**: Sparkle's `Autoupdate` binary lives at `Sparkle.framework/Versions/B/Autoupdate` (no `MacOS/` in path). The discovery function must search `*/Frameworks/*` in addition to `*/MacOS/*` to find it.

Use `--dry-run` to verify signing order without actually signing:
```bash
./scripts/sign-and-notarize.sh --dry-run dist/cctop.app
```

### Multi-Arch Appcast

`generate_appcast` (Sparkle's tool) cannot handle multiple ZIPs with the same bundle version. The script works around this by:
1. Normalizing input ZIP order so the arm64 ZIP is primary
2. Generating the appcast with only the arm64 ZIP
3. Marking the arm64 item with `sparkle:hardwareRequirements`
4. Signing the x86_64 ZIP separately with `sign_update`
5. Duplicating the generated item for x86_64 with its own `sparkle:cpu` enclosure
6. Validating that the latest appcast version has separate arm64 and x86_64 items

Do not put arm64 and x86_64 enclosures in the same `<item>`. Sparkle treats hardware requirements at the item level and exposes one update file URL per item, so a shared item can make Intel clients download the arm64 archive.

### Homebrew Caskroom PATH

Homebrew's sparkle cask only symlinks the `sparkle` binary to `/opt/homebrew/bin/`. The `generate_appcast` and `sign_update` tools live in `/opt/homebrew/Caskroom/sparkle/*/bin/` and the script auto-discovers this path.

### Debugging Release Failures

```bash
# Re-run signing locally with dry-run to check order
./scripts/sign-and-notarize.sh --dry-run dist/cctop.app

# Sign without notarizing (faster iteration)
./scripts/sign-and-notarize.sh --sign-only dist/cctop.app

# Test appcast generation locally
SPARKLE_PRIVATE_KEY_FILE=~/.sparkle_ed25519 ./scripts/generate-appcast.sh --version 0.7.0 arm64.zip x86_64.zip
```

If notarization fails, the script automatically fetches the notarization log via `xcrun notarytool log`. Common causes:
- Sparkle components signed with app entitlements (see signing strategy above)
- Unsigned binaries in non-standard paths (like `Autoupdate`)
- Missing hardened runtime flag

## Menubar Screenshot

The menubar screenshots (`docs/menubar-light.png` and `docs/menubar-dark.png`) are generated from a snapshot test that renders `PopupView` with mock data:

```bash
# Regenerate the menubar screenshots (light + dark)
xcodebuild test -project menubar/CctopMenubar.xcodeproj -scheme CctopMenubar \
  -only-testing:CctopMenubarTests/SnapshotTests/testGenerateMenubarScreenshot \
  -derivedDataPath menubar/build/ CODE_SIGN_IDENTITY="-"
cp /tmp/menubar-light.png /tmp/menubar-dark.png docs/
```

The showcase sessions are defined in `Session+Mock.swift` (`qaShowcase`). Edit that array to change what appears in the screenshots.

## Design Context

See [DESIGN.md](DESIGN.md) for the visual design system — color palettes per theme, typography ladder, component specs, layout principles, and the do's/don'ts that govern visual decisions. When making UI changes, treat DESIGN.md as the source of truth and update it if the implementation needs to evolve.
