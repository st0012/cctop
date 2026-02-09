# CLAUDE.md - Development Guide for cctop

## Project Overview

cctop is a TUI (Terminal User Interface) for monitoring Claude Code sessions across workspaces. It tracks session status (idle, working, needs attention) via Claude Code hooks and allows jumping to sessions.

## Architecture

```
cctop/
├── src/
│   ├── main.rs        # CLI entry point (TUI)
│   ├── lib.rs         # Library exports
│   ├── config.rs      # Config loading
│   ├── session.rs     # Session struct and status handling
│   ├── tui.rs         # Ratatui TUI implementation
│   ├── focus.rs       # Terminal focus
│   ├── git.rs         # Git branch detection
│   ├── watcher.rs     # File system watcher
│   └── bin/
│       └── cctop_hook.rs  # Hook binary
├── menubar/           # Swift/SwiftUI menubar app
│   ├── CctopMenubar.xcodeproj/
│   ├── CctopMenubar/
│   │   ├── CctopApp.swift         # App entry point
│   │   ├── AppDelegate.swift      # NSStatusItem + FloatingPanel toggle
│   │   ├── FloatingPanel.swift    # NSPanel subclass (stays open)
│   │   ├── Models/                # Session, SessionStatus (Codable)
│   │   ├── Views/                 # PopupView, SessionCardView, QuitButton, etc.
│   │   └── Services/              # SessionManager, FocusTerminal
│   └── CctopMenubarTests/
├── plugins/cctop/     # Claude Code plugin
│   ├── .claude-plugin/plugin.json
│   ├── hooks/hooks.json
│   └── skills/cctop-setup/SKILL.md
├── scripts/
│   └── bundle-macos.sh   # Build hybrid .app bundle
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

**Data flow:** The Swift app reads `~/.cctop/sessions/*.json` files written by `cctop-hook` (Rust). The JSON file format is the interface contract — no FFI.

**Key files:**
- `menubar/CctopMenubar/AppDelegate.swift` — NSStatusItem + FloatingPanel management
- `menubar/CctopMenubar/FloatingPanel.swift` — NSPanel subclass (persistent popup)
- `menubar/CctopMenubar/Views/PopupView.swift` — Main popup layout
- `menubar/CctopMenubar/Views/SessionCardView.swift` — Session card component
- `menubar/CctopMenubar/Models/Session.swift` — Session data model (Codable)
- `menubar/CctopMenubar/Services/SessionManager.swift` — File watching + session loading

## Key Components

### Binaries
- `cctop` - TUI application (Rust, ratatui)
- `cctop-hook` - Hook handler called by Claude Code (Rust)
- `CctopMenubar.app` - macOS menubar app (Swift/SwiftUI, built via Xcode)

### Data Flow
1. Claude Code fires hooks (SessionStart, UserPromptSubmit, Stop, etc.)
2. `cctop-hook` receives JSON via stdin, writes session files to `~/.cctop/sessions/`
3. Both the menubar app (SessionManager file watcher) and `cctop` TUI read these files and display live status

## Development Commands

```bash
# Build
cargo build --release

# Install binaries to ~/.cargo/bin
cargo install --path .

# Run TUI
cctop

# List sessions without TUI (useful for debugging)
cctop --list

# Run tests
cargo test

# Check a specific session file
cat ~/.cctop/sessions/<session-id>.json | jq '.'

# Generate state machine diagram (requires graphviz: brew install graphviz)
scripts/generate-state-diagram.sh              # opens /tmp/cctop-states.svg
scripts/generate-state-diagram.sh docs/out.svg # custom output path
```

### Visual Changes
- Use Xcode Previews (Canvas) for instant visual feedback on any SwiftUI view
- All views have `#Preview` blocks with mock data for different states

## Testing the Hooks

```bash
# Manually trigger a hook to create/update a session
echo '{"session_id":"test123","cwd":"/tmp","hook_event_name":"SessionStart"}' | ~/.cargo/bin/cctop-hook SessionStart

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
- Hooks use `$HOME/.cargo/bin/cctop-hook` - ensure it's installed via `cargo install --path .`
- Check hooks.json uses the full path, not bare `cctop-hook`

### Stale sessions showing
- Sessions store the PID of the Claude process and are validated by checking if that PID is still running
- For old sessions without PID, falls back to checking if a claude process is running in that directory
- Use `cctop --list` to see current sessions and trigger cleanup
- Manual cleanup: `rm ~/.cctop/sessions/<session-id>.json`

### Jump to session not working
- Uses `code --goto <path>` to focus VS Code window
- For other editors, configure in `~/.cctop/config.toml`:
  ```toml
  [editor]
  process_name = "Cursor"
  cli_command = "cursor"
  ```

## Session Status Logic

6-status model with `NeedsAttention` as `#[serde(other)]` fallback for forward compatibility. Transitions are centralized in `Transition::for_event()` (`src/session.rs`) with typed `HookEvent` enum. Run `scripts/generate-state-diagram.sh` to visualize the state machine (or `cctop --dot` for raw DOT output).

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

Note: SessionEnd hook is no longer used. Dead sessions are detected via PID checking.

## Hook Delivery Debugging

cctop has a 4-component hook delivery chain. When sessions stop updating,
use per-session logs in `~/.cctop/logs/` to identify which component failed.

### The Chain

```
Claude Code fires hook -> run-hook.sh (SHIM) -> cctop-hook (HOOK) -> session file -> menubar/TUI
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
| SHIM entries but no HOOK entries | cctop-hook binary not starting | Run `cargo install --path .`, check paths |
| HOOK entries but session file stale | File write failure | Check disk space, permissions on ~/.cctop/sessions/ |
| HOOK entries present and session file fresh | Menubar/TUI file watcher issue | Restart the menubar app or TUI |
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

## Demo Recording

Uses [VHS](https://github.com/charmbracelet/vhs) for scriptable terminal recordings.

### Setup
```bash
brew install vhs
```

### Recording
```bash
# Generate demo GIF from tape file
vhs docs/demo.tape
```

### Tape File Format
The `docs/demo.tape` file defines the recording:
- `Output <path>` - Output file (GIF, MP4, WebM)
- `Set FontSize/Width/Height/Theme` - Terminal appearance
- `Type "<text>"` - Type text
- `Enter/Down/Up` - Key presses
- `Sleep <duration>` - Wait between actions

### Menubar Screenshot
The menubar screenshot (`docs/menubar.png`) is generated from a snapshot test that renders `PopupView` with mock data:

```bash
# Regenerate the menubar screenshot
xcodebuild test -project menubar/CctopMenubar.xcodeproj -scheme CctopMenubar \
  -only-testing:CctopMenubarTests/SnapshotTests/testGenerateMenubarScreenshot \
  -derivedDataPath menubar/build/ CODE_SIGN_IDENTITY="-"
cp /tmp/menubar.png docs/menubar.png
```

The mock sessions are defined in `Session+Mock.swift`. Edit `mockSessions` to change what appears in the screenshot.

### Tips
- Run with active Claude Code sessions for realistic content
- Or create mock session files in `~/.cctop/sessions/` before recording
- Re-run `vhs docs/demo.tape` to regenerate after changes

## Agent Workflow Guidelines

Learned from development. Rust changes often flow sequentially (session.rs -> cctop_hook.rs -> tui.rs). The Swift menubar (`menubar/`) is mostly independent from the Rust TUI.

### When to use what

**Subagents** (focused, report-back-only): quick research ("what's the convention for X?"), codebase exploration, code review after milestones. Use when only the result matters, not discussion.

**Agent teams** (inter-agent communication): debating approaches with competing hypotheses, parallel code review with different lenses, cross-file implementation where each teammate owns different files. Use when agents need to challenge each other or coordinate.

**Solo** (no agents): sequential changes across coupled files, small fixes, tasks where context transfer overhead exceeds benefit.

### Team best practices for this project
- Use **delegate mode** (Shift+Tab) to keep the lead in coordination-only role
- Design tasks around **file ownership**, not domain expertise (e.g., "own tui.rs" not "be a UX expert")
- Aim for **5-6 tasks per teammate** to keep them productive
- **Require plan approval** for implementation tasks
- session.rs is the shared interface — have one teammate own it, others depend on it
- Swift menubar (`menubar/`) is independent from the Rust TUI — good split for parallel work
