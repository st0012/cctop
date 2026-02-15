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
├── plugins/opencode/  # opencode plugin (JS, runs in-process in Bun)
│   ├── plugin.js      # Event handler, writes session JSON directly
│   └── package.json   # Plugin manifest
├── scripts/
│   └── bundle-macos.sh   # Build and bundle .app
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

**Data flow:** The menubar app reads `~/.cctop/sessions/*.json` files. These are written by `cctop-hook` (Swift CLI, for Claude Code) or the opencode JS plugin. Both Xcode targets share model code.

**Key files:**
- `menubar/CctopMenubar/AppDelegate.swift` — NSStatusItem + FloatingPanel management
- `menubar/CctopMenubar/FloatingPanel.swift` — NSPanel subclass (persistent popup)
- `menubar/CctopMenubar/Views/PopupView.swift` — Main popup layout
- `menubar/CctopMenubar/Views/SessionCardView.swift` — Session card component
- `menubar/CctopMenubar/Models/Session.swift` — Session data model (Codable, shared)
- `menubar/CctopMenubar/Models/HookEvent.swift` — Hook event enum + transition logic (shared)
- `menubar/CctopMenubar/Models/Config.swift` — JSON config, sessions dir (shared)
- `menubar/CctopMenubar/Services/SessionManager.swift` — File watching + session loading
- `menubar/CctopMenubar/Hook/HookMain.swift` — CLI entry point (cctop-hook target only)
- `menubar/CctopMenubar/Hook/HookHandler.swift` — Core hook logic (cctop-hook target only)
- `menubar/CctopMenubar/Hook/SessionNameLookup.swift` — Session name lookup from transcript/index (cctop-hook target only)
- `plugins/opencode/plugin.js` — opencode plugin (event handler, writes session JSON directly)

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

## Key Components

### Binaries
- `CctopMenubar.app` - macOS menubar app (Swift/SwiftUI, built via Xcode)
- `cctop-hook` - Hook handler called by Claude Code (Swift CLI, Xcode target in same project)
- `plugins/opencode/plugin.js` - opencode plugin (JS, runs in-process in Bun, zero dependencies)

### Data Flow

**Claude Code path:**
1. Claude Code fires hooks (SessionStart, UserPromptSubmit, Stop, etc.)
2. `run-hook.sh` (shell shim) dispatches to `cctop-hook` (Swift CLI)
3. `cctop-hook` writes session files to `~/.cctop/sessions/`

**opencode path:**
1. opencode fires plugin events (session.created, chat.message, tool.execute.before, etc.)
2. `plugin.js` runs in-process and writes session files directly to `~/.cctop/sessions/`

**Both paths converge:** The menubar app (SessionManager file watcher) reads `~/.cctop/sessions/*.json` and displays live status regardless of source. Sessions include a `source` field (`nil` for Claude Code, `"opencode"` for opencode).

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

### "command not found" errors
- Hooks search for `cctop-hook` in `/Applications/cctop.app/Contents/MacOS/` and `~/Applications/cctop.app/Contents/MacOS/`
- Ensure the app is installed in one of those locations

### Stale sessions showing
- Sessions store the PID of the Claude process and are validated by checking if that PID is still running
- Manual cleanup: `rm ~/.cctop/sessions/<pid>.json`
- In-app reset: right-click a session in the menubar to reset status to idle

### Jump to session not working
- **VS Code / Cursor (menubar app)**: Runs `code <path>` or `cursor <path>` to focus the project window. If a `.code-workspace` file is detected in the project directory, it's passed instead of the folder path.
- **VS Code / Cursor (Raycast extension)**: Uses `open -a "Visual Studio Code" <path>` because Raycast's sandboxed Node.js doesn't have `/usr/local/bin` in PATH. The `code` CLI cannot be called directly.
- **Workspace limitation**: cctop detects workspace files by scanning the project directory at session start. If the project folder contains a `.code-workspace` file but you opened the folder directly (not via the workspace file), cctop may incorrectly open the workspace instead of focusing the folder window. VS Code does not expose which mode was used via environment variables or APIs.
- **iTerm2**: Uses AppleScript to match the session's `ITERM_SESSION_ID` GUID against iTerm2's `unique id` property. Raises the correct window (`set index of w to 1`), selects the tab, and focuses the pane. Falls back to generic `app.activate()` if the session ID is missing or stale. Requires macOS Automation permission (prompted on first use via `NSAppleEventsUsageDescription`).
- **Other terminals**: Falls back to `NSRunningApplication.activate()` (activates the app but cannot target a specific window).

## Session Status Logic

6-status model with forward-compatible decoding (unknown statuses map to `.needsAttention`). Transitions are centralized in `HookEvent.swift` (Claude Code) and `plugin.js` (opencode).

### Claude Code Hook Events

| Hook Event | Status |
|------------|--------|
| SessionStart | idle (also stores PID for liveness detection) |
| UserPromptSubmit | working |
| PreToolUse | working (sets last_tool/last_tool_detail) |
| PostToolUse | working |
| Stop | idle |
| Notification (idle_prompt) | waiting_input |
| Notification (permission_prompt) | waiting_permission |
| PermissionRequest | waiting_permission |
| PreCompact | compacting |

### opencode Plugin Events

| Plugin Event | Status |
|------------|--------|
| session.created | idle |
| chat.message | working |
| tool.execute.before | working (sets last_tool/last_tool_detail) |
| tool.execute.after | working |
| session.idle | waiting_input (opencode is always interactive) |
| session.status (busy) | working |
| session.status (retry) | needs_attention |
| permission.ask | waiting_permission |
| permission.replied | working |
| session.error | needs_attention |
| session.updated | (extracts session title) |
| session.deleted | no-op (liveness check handles cleanup) |
| experimental.session.compacting | compacting |
| session.compacted | idle |

### Session File Format

Session files are keyed by PID (`{pid}.json`), not session_id. Each file stores `pid_start_time` (from `sysctl`) to detect PID reuse. Dead sessions are detected via PID liveness + start time checking. opencode sessions include `"source": "opencode"` in the JSON; Claude Code sessions omit the field (nil = Claude Code).

## Hook Delivery Debugging

cctop has a 4-component hook delivery chain. When sessions stop updating,
use per-session logs in `~/.cctop/logs/` to identify which component failed.

### The Chain

```
Claude Code fires hook -> run-hook.sh (SHIM) -> cctop-hook (HOOK) -> session file -> menubar app
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

The opencode plugin runs in-process (no SHIM/HOOK chain). Debugging is simpler:

| Symptom | Cause | Fix |
|---------|-------|-----|
| No session file appears | Plugin not installed or not loaded | Install via Settings > Monitored Tools, verify `~/.config/opencode/plugins/cctop.js` exists, restart opencode |
| Session file appears but status doesn't update | Plugin event handler error | Check opencode logs for JS errors |
| Session stuck in waiting_permission | `permission.replied` event not handled | Update plugin to latest version |

```bash
# Check if the plugin is installed
ls ~/.config/opencode/plugins/cctop.js

# Check if session files are being written
ls -lt ~/.cctop/sessions/

# Verify the source field
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
