# CLAUDE.md - Development Guide for cctop

## Project Overview

cctop is a macOS menubar app for monitoring Claude Code sessions across workspaces. It tracks session status (idle, working, needs attention) via Claude Code hooks and allows jumping to sessions.

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
├── plugins/cctop/     # Claude Code plugin
│   ├── .claude-plugin/plugin.json
│   ├── hooks/hooks.json
│   └── skills/cctop-setup/SKILL.md
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

**Data flow:** The menubar app reads `~/.cctop/sessions/*.json` files written by `cctop-hook` (Swift CLI). Both are built from the same Xcode project with shared model code.

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

## Key Components

### Binaries
- `CctopMenubar.app` - macOS menubar app (Swift/SwiftUI, built via Xcode)
- `cctop-hook` - Hook handler called by Claude Code (Swift CLI, Xcode target in same project)

### Data Flow
1. Claude Code fires hooks (SessionStart, UserPromptSubmit, Stop, etc.)
2. `cctop-hook` receives JSON via stdin, writes session files to `~/.cctop/sessions/`
3. The menubar app (SessionManager file watcher) reads these files and displays live status

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

## Plugin Installation (Local Development)

```bash
# Add the local marketplace
claude plugin marketplace add /path/to/cctop

# Install the plugin
claude plugin install cctop

# Verify installation
ls ~/.claude/plugins/cache/cctop/
```

After installing, **restart Claude Code sessions** to pick up the hooks.

## Common Issues

### Hooks not firing
- Check if plugin is installed: `claude plugin list`
- Hooks only load at session start - restart the session
- Check debug logs: `grep cctop ~/.claude/debug/<session-id>.txt`

### "command not found" errors
- Hooks search for `cctop-hook` in `/Applications/cctop.app/Contents/MacOS/` and `~/Applications/cctop.app/Contents/MacOS/`
- Ensure the app is installed in one of those locations

### Stale sessions showing
- Sessions store the PID of the Claude process and are validated by checking if that PID is still running
- Manual cleanup: `rm ~/.cctop/sessions/<pid>.json`
- In-app reset: right-click a session in the menubar to reset status to idle

### Jump to session not working
- **VS Code / Cursor**: Uses the CLI binary inside the app bundle (e.g. `Visual Studio Code.app/.../bin/code <path>`) to focus the project window. Falls back to `open -a` if the CLI isn't found. No shell PATH dependency.
- **Other editors**: Falls back to `NSRunningApplication.activate()` (activates the app but cannot target a specific window).

## Session Status Logic

6-status model with forward-compatible decoding (unknown statuses map to `.needsAttention`). Transitions are centralized in `HookEvent.swift` with typed `HookEvent` enum and `Transition` struct.

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

Note: Session files are keyed by PID (`{pid}.json`), not session_id. Each file stores `pid_start_time` (from `sysctl`) to detect PID reuse. SessionEnd hook is no longer used — dead sessions are detected via PID liveness + start time checking.

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

Learned from development. The codebase is now pure Swift with two Xcode targets sharing model code. Changes to shared models (Models/) affect both the menubar app and cctop-hook CLI.

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
