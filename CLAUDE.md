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

**Key files:**
- `menubar/CctopMenubar/AppDelegate.swift` — NSStatusItem + FloatingPanel management
- `menubar/CctopMenubar/FloatingPanel.swift` — NSPanel subclass (persistent popup)
- `menubar/CctopMenubar/Views/PopupView.swift` — Main popup layout
- `menubar/CctopMenubar/Views/SessionCardView.swift` — Session card component
- `menubar/CctopMenubar/Models/Session.swift` — Session data model (Codable, shared)
- `menubar/CctopMenubar/Models/HookEvent.swift` — Hook event enum + transition logic (shared)
- `menubar/CctopMenubar/Models/Config.swift` — JSON config, sessions dir (shared)
- `menubar/CctopMenubar/Services/SessionManager.swift` — File watching + session loading
- `menubar/CctopMenubar/Services/NotchStatusController.swift` — Notch status panel lifecycle
- `menubar/CctopMenubar/Views/NotchStatusPanel.swift` — NSPanel for notch area display
- `menubar/CctopMenubar/Views/NotchStatusView.swift` — SwiftUI view for notch status pill
- `menubar/CctopMenubar/Views/MenubarIconRenderer.swift` — Menubar icon with proportional status bar
- `menubar/CctopMenubar/Models/StatusCounts.swift` — Aggregated session counts, bar segments, accessibility labels
- `menubar/CctopMenubar/Models/StatusColors.swift` — Shared status bar colors (RGBColor with NSColor + SwiftUI Color)
- `menubar/CctopMenubar/Models/Color+Theme.swift` — Theme-aware color tokens (textPrimary, textSecondary, textMuted, amber, etc.)
- `menubar/CctopMenubar/Extensions/NSScreen+Notch.swift` — Notch detection extension
- `menubar/CctopMenubar/Hook/HookMain.swift` — CLI entry point (cctop-hook target only)
- `menubar/CctopMenubar/Hook/HookHandler.swift` — Core hook logic (cctop-hook target only)
- `menubar/CctopMenubar/Hook/SessionNameLookup.swift` — Session name lookup from transcript/index (cctop-hook target only)
- `plugins/opencode/plugin.js` — opencode plugin (translates events to cctop-hook calls)
- `plugins/pi/cctop.ts` — pi extension (translates events to cctop-hook calls, skips non-interactive sessions)

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
- **Codex CLI**: Uses Codex's experimental lifecycle hooks system (feature flag `codex_hooks = true` in `~/.codex/config.toml`). The cctop install flow writes a shell shim to `~/.codex/cctop-shim.sh`, merges five hook entries into `~/.codex/hooks.json` (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop), and enables the feature flag. Each event fires `$SHELL -lc "~/.codex/cctop-shim.sh <Event>"`, which execs `cctop-hook` with `--harness codex`. **Codex quirks to know about:** interactive `codex` does NOT fire `SessionStart` at cold launch — it fires SessionStart immediately before the first `UserPromptSubmit`, so cctop won't display an interactive codex session until the user submits their first prompt. Tool tracking is limited to shell calls (Codex only emits `PreToolUse`/`PostToolUse` for its `local_shell` tool today). No `SessionEnd` event — dead sessions are cleaned up via PID liveness.

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

## Plugin Installation (Local Development)

### Claude Code

```bash
# Add the local marketplace
claude plugin marketplace add /path/to/cctop

# Install the plugin
claude plugin install cctop

# Verify installation
ls ~/.claude/plugins/cache/cctop/
```

After installing, **restart Claude Code sessions** to pick up the hooks.

### opencode

The menubar app detects opencode when `~/.config/opencode/` exists and offers to install the plugin via the UI (Settings > Monitored Tools or the install banner). Click "Install Plugin", then restart opencode.

### pi

The menubar app detects pi when `~/.pi/` exists and offers to install the extension via the UI (Settings > Monitored Tools or the install banner). Click "Install Plugin", then restart pi. The extension is installed to `~/.pi/agent/extensions/cctop.ts`.

## Common Issues

### Hooks not firing (Claude Code)
- Check if plugin is installed: `claude plugin list`
- Hooks only load at session start - restart the session
- Check debug logs: `grep cctop ~/.claude/debug/<session-id>.txt`

### Plugin not working (opencode)
- The app detects opencode when `~/.config/opencode/` exists and offers to install via the UI
- Install the plugin via Settings > Monitored Tools or the install banner
- Check if plugin file exists: `ls ~/.config/opencode/plugins/cctop.js`
- Restart opencode after installing the plugin
- Check for session files: `ls ~/.cctop/sessions/`

### Extension not working (pi)
- The app detects pi when `~/.pi/` exists and offers to install via the UI
- Install the extension via Settings > Monitored Tools or the install banner
- Check if extension file exists: `ls ~/.pi/agent/extensions/cctop.ts`
- Restart pi after installing the extension (or use `/reload` in pi)
- Check for session files: `ls ~/.cctop/sessions/`

### "command not found" errors
- Hooks search for `cctop-hook` in `/Applications/cctop.app/Contents/MacOS/` and `~/Applications/cctop.app/Contents/MacOS/`
- Ensure the app is installed in one of those locations

### Stale sessions showing
- Sessions store the PID of the Claude process and are validated by checking if that PID is still running
- Manual cleanup: `rm ~/.cctop/sessions/<pid>.json`

### Jump to session not working
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

## opencode Plugin Debugging

The opencode plugin now calls `cctop-hook`, so per-session logs (`~/.cctop/logs/`) work the same as Claude Code. The plugin calls `execFileSync` for each event — if cctop-hook isn't found, calls silently fail.

| Symptom | Cause | Fix |
|---------|-------|-----|
| No session file appears | Plugin not installed, or cctop-hook not found | Verify plugin: `ls ~/.config/opencode/plugins/cctop.js`. Verify binary: `ls /Applications/cctop.app/Contents/MacOS/cctop-hook` or `~/.cctop/bin/cctop-hook` |
| No HOOK entries in logs | Plugin calling hook but binary failing | Check `~/.cctop/logs/_errors.log` for parse errors |
| Session file appears but status doesn't update | Plugin event handler error or stale plugin | Check opencode logs for JS errors; update plugin via Settings > Monitored Tools |

```bash
# Check if the plugin is installed
ls ~/.config/opencode/plugins/cctop.js

# Check if session files are being written
ls -lt ~/.cctop/sessions/

# Check per-session hook logs (same as Claude Code now)
ls ~/.cctop/logs/

# Verify the source field
cat ~/.cctop/sessions/*.json | jq '{project: .project_name, status: .status, source: .source}'
```

## pi Extension Debugging

The pi extension calls `cctop-hook`, so per-session logs (`~/.cctop/logs/`) work the same as other tools. Non-interactive sessions (`ctx.hasUI === false`) are silently skipped — no session file or log will be created.

| Symptom | Cause | Fix |
|---------|-------|-----|
| No session file appears | Extension not installed, cctop-hook not found, or session is non-interactive | Verify extension: `ls ~/.pi/agent/extensions/cctop.ts`. Verify binary exists. Check if pi is running in background mode (`-p`, `--mode json`). |
| No HOOK entries in logs | Extension calling hook but binary failing | Check `~/.cctop/logs/_errors.log` for parse errors |
| Session file appears but status doesn't update | Extension event handler error | Check pi console for TS errors; reinstall extension via Settings |

```bash
# Check if the extension is installed
ls ~/.pi/agent/extensions/cctop.ts

# Check if session files are being written
ls -lt ~/.cctop/sessions/

# Verify the source field shows "pi"
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

## Files to Check When Debugging

- `~/.cctop/logs/{session_id}.log` - Per-session hook delivery logs (SHIM/HOOK entries)
- `~/.cctop/logs/_errors.log` - Pre-parse errors (before session ID is known)
- `~/.cctop/sessions/*.json` - Session state files
- `~/.claude/debug/<session-id>.txt` - Claude Code debug logs
- `~/.claude/plugins/cache/cctop/` - Installed plugin cache
- `~/.claude/settings.json` - Check if plugin is enabled

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
1. Generating the appcast with only the arm64 ZIP
2. Signing the x86_64 ZIP separately with `sign_update`
3. Using Python3 to add the x86_64 enclosure with `sparkle:cpu` attributes

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

## Agent Workflow Guidelines

Learned from development. The menubar app is pure Swift with two Xcode targets sharing model code. The Raycast extension is TypeScript/React. Changes to shared models (Models/) affect both the menubar app and cctop-hook CLI. The Raycast extension has its own TypeScript types (`types.ts`) that mirror the Swift models.

### When to use what

**Subagents** (focused, report-back-only): quick research ("what's the convention for X?"), codebase exploration, code review after milestones. Use when only the result matters, not discussion.

**Agent teams** (inter-agent communication): debating approaches with competing hypotheses, parallel code review with different lenses, cross-file implementation where each teammate owns different files. Use when agents need to challenge each other or coordinate.

**Solo** (no agents): sequential changes across coupled files, small fixes, tasks where context transfer overhead exceeds benefit.

### Team best practices for this project
- Use **delegate mode** (Shift+Tab) to keep the lead in coordination-only role
- Design tasks around **file ownership**, not domain expertise
- Aim for **5-6 tasks per teammate** to keep them productive
- **Require plan approval** for implementation tasks
- Models/ files are the shared interface — changes here affect both targets
- Hook/ files are cctop-hook only, Views/Services are menubar only — good split for parallel work
- `raycast/` is independent of the Swift code — changes there don't affect menubar/cctop-hook builds
- If the session JSON format changes (Models/Session.swift), update `raycast/src/types.ts` to match

## Design Context

### Users
Developers monitoring multiple AI coding sessions (Claude Code, opencode) across workspaces. They glance at cctop in their periphery — it should convey status at a glance without demanding attention. The job: know which sessions need action, jump to them fast, then get back to work.

### Brand Personality
**Calm, precise, utilitarian.** cctop is a well-made instrument — no fuss, just works. But the craft shows in the details: the neutral color palette, the considered spacing, the keyboard-first interactions. It should feel like a quality indie Mac app, not a generic system utility.

### Aesthetic Direction
- **Visual tone:** Understated and neutral. A red accent (#ff6b6b dark / #d03830 light) provides identity without being loud. Neutral grays for text hierarchy (no warm/cool tinting). Dark mode is the primary context (developers), light mode should feel equally considered.
- **Color system:** "Apple Native" (Option C) — named tokens in `Color+Theme.swift`: `textPrimary` (#f0f0f0/#1a1a1a), `textSecondary` (#9e9e9e/#666), `textMuted` (#666/#999), `amber` (the red accent), `panelBackground` (#1e1e1e/#fff). Light mode values are intentionally darker than typical to maintain contrast at small font sizes (10-11px).
- **References:** Linear and Raycast (fast, keyboard-first, opinionated); Things 3 and Bear (indie Mac warmth, understated elegance, attention to detail).
- **Anti-references:** Electron-feeling apps with web-like UI. Overly branded dashboards. Anything that looks like a monitoring tool from an ops context (Grafana, Datadog). Generic system preferences.
- **Theme:** Both light and dark, fully theme-aware. All colors defined with explicit light/dark variants in `Color+Theme.swift`. Status bar colors (RGB) are appearance-independent.
- **Corner radius system:** 4 for small inline elements (chips, badges), 6 for controls (tabs, session cards), 10 for panels.
- **Font size system:** 11px medium for settings labels, 10px for secondary text (badges, hints, section headers). Session cards use 12-13px for primary content.

### Design Principles
1. **Glanceable over interactive.** Status should be understood in under a second. Minimize cognitive load — color + text pairing, proportional status bars, spatial consistency.
2. **Native over novel.** Use San Francisco, standard macOS patterns, system-level behaviors (NSPanel, NSStatusItem). It should feel like part of the OS, not a foreign app.
3. **Craft in the details.** Joy comes from noticing care — the neutral palette, the smooth keyboard navigation, the proportional status bar segments. Never flashy, always considered.
4. **Function earns its pixels.** Every element must justify its space. No decorative chrome, no padding for padding's sake. Dense but not cramped — utilitarian density with breathing room.
5. **Keyboard-first, mouse-friendly.** Navigate mode (1-9 keys), arrow keys, Tab switching — power users never touch the trackpad. But hover states and click targets are equally polished.
6. **Prototype in HTML first.** Design changes are prototyped as self-contained HTML files (saved to `/tmp/`), reviewed in browser, then implemented in Swift with exact matching values. This prevents drift between design intent and implementation.
