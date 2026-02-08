# CLAUDE.md - Development Guide for cctop

## Project Overview

cctop is a TUI (Terminal User Interface) for monitoring Claude Code sessions across workspaces. It tracks session status (idle, working, needs attention) via Claude Code hooks and allows jumping to sessions.

## Architecture

```
cctop/
├── src/
│   ├── main.rs        # CLI entry point, --list flag
│   ├── lib.rs         # Library exports
│   ├── config.rs      # Config loading from ~/.cctop/config.toml
│   ├── session.rs     # Session struct and status handling
│   ├── tui.rs         # Ratatui TUI implementation
│   ├── focus.rs       # Terminal focus (VS Code, iTerm2, Kitty)
│   ├── git.rs         # Git branch detection
│   ├── menubar/
│   │   ├── app.rs         # macOS menubar app event loop
│   │   ├── popup.rs       # Popup rendering (egui)
│   │   ├── popup_state.rs # Popup visibility state
│   │   ├── renderer.rs    # wgpu + egui GPU renderer
│   │   ├── snapshot.rs    # Headless popup snapshot renderer
│   │   └── menu.rs        # Native menu building
│   └── bin/
│       └── cctop_hook.rs  # Hook binary called by Claude Code
├── plugins/cctop/     # Claude Code plugin
│   ├── .claude-plugin/plugin.json
│   ├── hooks/hooks.json
│   └── skills/cctop-setup/SKILL.md
└── .claude-plugin/
    └── marketplace.json  # For local plugin installation
```

### Swift Menubar App

The macOS menubar app is built with Swift/SwiftUI (replacing the previous Rust/egui implementation).

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
- `menubar/CctopMenubar/CctopApp.swift` — MenuBarExtra entry point
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
3. `cctop` TUI reads session files and displays them

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
```

## Visual Snapshot Testing

The menubar popup can be rendered to a PNG without launching the app. This is essential for verifying visual changes to `popup.rs`.

### When to use
- **After ANY visual change to `popup.rs`** (colors, layout, spacing, rendering)
- Before committing popup UI changes
- When debugging visual issues reported by the user

### How to generate snapshots
```bash
# Run the snapshot test to generate PNGs
cargo test snapshot -- --nocapture

# View the generated snapshots
open /tmp/cctop_snapshot_typical.png
open /tmp/cctop_snapshot_empty.png
```

### How it works
- `src/menubar/snapshot.rs` creates a headless wgpu device (no window needed)
- Renders using the exact same egui pipeline as the real app
- Output is pixel-perfect to what the user sees
- Uses 2x scale factor for Retina-quality output

### Comparing against the design
The target design mockup is in `/Users/st0012/Downloads/cctop-redesigns.jsx` (Design B). Compare the snapshot PNG against the Design B screenshot to verify visual correctness.

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
claude plugin marketplace add /Users/st0012/projects/cctop

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

4-status model with `NeedsAttention` as `#[serde(other)]` fallback for forward compatibility.

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
| PreCompact | (preserves status, sets context_compacted) |

Note: SessionEnd hook is no longer used. Dead sessions are detected via PID checking.

## Debugging Tips

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

### Tips
- Run with active Claude Code sessions for realistic content
- Or create mock session files in `~/.cctop/sessions/` before recording
- Re-run `vhs docs/demo.tape` to regenerate after changes

## Agent Workflow Guidelines

Learned from Phase 1-2 development. Changes in this codebase often flow sequentially (session.rs -> cctop_hook.rs -> tui.rs -> popup.rs -> menu.rs), which limits parallelization.

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
- Menubar (popup.rs, app.rs, menu.rs) is mostly independent from TUI (tui.rs) — good split for parallel work
