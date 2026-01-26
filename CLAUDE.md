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
│   └── bin/
│       └── cctop_hook.rs  # Hook binary called by Claude Code
├── plugins/cctop/     # Claude Code plugin
│   ├── .claude-plugin/plugin.json
│   ├── hooks/hooks.json
│   └── skills/cctop-setup/SKILL.md
└── .claude-plugin/
    └── marketplace.json  # For local plugin installation
```

## Key Components

### Binaries
- `cctop` - TUI application
- `cctop-hook` - Hook handler called by Claude Code on session events

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
- Sessions are validated by checking if a claude process is running in that directory
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

| Hook Event | Status |
|------------|--------|
| SessionStart | idle |
| UserPromptSubmit | working |
| PreToolUse | working |
| PostToolUse | working |
| Stop | idle |
| Notification (idle_prompt) | needs_attention |
| SessionEnd | (file deleted) |

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
