# cctop - Claude Code Session Monitor

A TUI for monitoring Claude Code sessions across VS Code workspaces.

## Problem

When running multiple Claude Code sessions across different VS Code workspaces:
- Hard to track which sessions need attention (waiting for input)
- No visibility into session state without manually checking each terminal
- Friction switching between workspaces to check status
- Easy to forget about running sessions

## Goals

1. **Discover** all running CC sessions on the machine
2. **Display** status: idle, working, or needs attention
3. **Show** context: repo, branch, last prompt, last activity time
4. **Navigate** to the session with one keypress

## Non-Goals (for v1)

- Starting new CC sessions
- Sending input to sessions remotely
- Multi-machine support
- tmux integration (already solved by other tools)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Claude Code Plugin                          │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  hooks.json                                              │   │
│  │  - SessionStart → write session.json                     │   │
│  │  - UserPromptSubmit → update last_prompt                 │   │
│  │  - PreToolUse → status = "working"                       │   │
│  │  - PostToolUse → status = "idle"                         │   │
│  │  - Stop → status = "idle"                                │   │
│  │  - SessionEnd → remove session.json                      │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  ~/.cctop/sessions/<session-id>.json                     │   │
│  │  {                                                       │   │
│  │    "session_id": "abc123",                               │   │
│  │    "project_path": "/Users/st0012/projects/irb",        │   │
│  │    "status": "working" | "idle" | "needs_attention",     │   │
│  │    "last_prompt": "Fix the bug in...",                   │   │
│  │    "last_activity": "2026-01-25T22:48:00Z",              │   │
│  │    "branch": "main"                                      │   │
│  │  }                                                       │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     cctop TUI (Rust + Ratatui)                  │
│                                                                 │
│  - Polls ~/.cctop/sessions/*.json every 200ms                   │
│  - Groups sessions by status                                    │
│  - Enter → focus VS Code window (AppleScript)                   │
│  - Displays: project name, branch, status, last prompt, time    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Distribution | CC Plugin + `cargo install cctop` | Plugin installs hooks, runs cargo install for binaries. Avoids macOS signing issues. |
| Status source | CC hooks | Accurate, real-time, proven by Claude HUD |
| Data location | ~/.cctop/sessions/ | Clean separation from CC internals |
| TUI framework | Rust + Ratatui | Fast, single binary, good ecosystem |
| Hook binary | Rust (same crate) | Single crate produces `cctop` and `cctop-hook`. Consistent, one build. |
| Window focus | Multi-terminal support | VS Code, iTerm2, Kitty (best), Terminal.app, others (app-level) |
| Display mode | Grouped by status | Scannable, Needs Attention at top |
| Prompt display | 50-80 chars, truncated | Keeps UI compact |

---

## Status Classification

| Hook Event | Status Transition | Rationale |
|------------|-------------------|-----------|
| SessionStart | → idle | Session just started, waiting for user input |
| UserPromptSubmit | → working | User submitted prompt, Claude is processing |
| PreToolUse | → working | Claude is actively using tools |
| PostToolUse | → working | Tool finished, but Claude may use more tools |
| Stop | → idle | Claude finished responding, waiting for next prompt |
| Notification (idle_prompt) | → needs_attention | Claude explicitly waiting for user action |

**Status Flow:**
```
SessionStart → idle
     ↓
UserPromptSubmit → working
     ↓
PreToolUse → working ←─┐
     ↓                 │
PostToolUse → working ─┘ (loop while using tools)
     ↓
Stop → idle
     ↓
Notification (idle_prompt) → needs_attention
```

**Needs Attention Detection:**
- Only triggered by `Notification` hook with `idle_prompt` type
- No timeout heuristic (avoids false positives when user is on break)

---

## Component Details

### 1. CC Plugin (hooks + status writer)

**File: hooks/hooks.json**
```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/bin/cctop-hook SessionStart"
      }]
    }],
    "UserPromptSubmit": [{
      "hooks": [{
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/bin/cctop-hook UserPromptSubmit"
      }]
    }],
    "PreToolUse": [{
      "hooks": [{
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/bin/cctop-hook PreToolUse"
      }]
    }],
    "PostToolUse": [{
      "hooks": [{
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/bin/cctop-hook PostToolUse"
      }]
    }],
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/bin/cctop-hook Stop"
      }]
    }],
    "SessionEnd": [{
      "hooks": [{
        "type": "command",
        "command": "${CLAUDE_PLUGIN_ROOT}/bin/cctop-hook SessionEnd"
      }]
    }]
  }
}
```

**Hook binary (cctop-hook):**
- Takes hook name as first argument (SessionStart, UserPromptSubmit, etc.)
- Reads JSON from stdin (schema below)
- Captures terminal info from environment ($TERM_PROGRAM, $ITERM_SESSION_ID, $KITTY_WINDOW_ID, $TTY)
- Runs `git branch --show-current` in cwd to get branch name (falls back to "unknown" on error)
- Writes session file atomically (write to temp file, then rename)
- On SessionEnd: removes the session file

**Stdin JSON schema (from Claude Code):**
```json
{
  "session_id": "abc123-def456",           // Always present
  "cwd": "/Users/st0012/projects/irb",     // Always present
  "transcript_path": "~/.claude/...",      // Always present
  "permission_mode": "default",            // Always present
  "hook_event_name": "UserPromptSubmit",   // Always present
  "prompt": "Fix the bug...",              // Only for UserPromptSubmit
  "tool_name": "Bash",                     // Only for PreToolUse/PostToolUse
  "notification_type": "idle_prompt"       // Only for Notification
}
```

**Error handling:**
- Invalid JSON stdin → log error, exit 0 (don't block CC)
- Git command fails → use "unknown" as branch
- Can't write session file → log error, exit 0
- Session file doesn't exist on SessionEnd → no-op

### 2. Session JSON Schema

```json
{
  "session_id": "abc123-def456",
  "project_path": "/Users/st0012/projects/irb",
  "project_name": "irb",
  "branch": "main",
  "status": "working",
  "last_prompt": "Fix the completion bug when...",
  "last_activity": "2026-01-25T22:48:00.000Z",
  "started_at": "2026-01-25T22:30:00.000Z",
  "terminal": {
    "program": "iTerm.app",
    "session_id": "w0t0p0:12345678-ABCD-...",
    "tty": "/dev/ttys003"
  }
}
```

**Terminal detection:** Hook captures from environment:
- `$TERM_PROGRAM` → terminal.program (iTerm.app, Apple_Terminal, vscode, kitty, etc.)
- `$ITERM_SESSION_ID` → terminal.session_id (iTerm2 only)
- `$KITTY_WINDOW_ID` → terminal.session_id (Kitty only)
- `$TTY` → terminal.tty

**Atomic writes:** To avoid race conditions when multiple hooks fire simultaneously:
1. Write to temp file: `~/.cctop/sessions/<session_id>.json.tmp`
2. Rename to final path (atomic on POSIX)
3. Each session has unique ID, so different sessions don't conflict

### 3. TUI Layout

```
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃  cctop                                                 3 sessions   ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

  NEEDS ATTENTION ─────────────────────────────────────────────────────

  → ruby/irb         main         5m ago
    "Draft social post for ruby-skills announcement"

  WORKING ─────────────────────────────────────────────────────────────

  ◉ ruby/rdoc        markdown-fix  12s ago
    "Fix GFM table parsing edge cases"

  IDLE ────────────────────────────────────────────────────────────────

  · ruby-skills      main          2m ago
    "Add completion support for Hash keys"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ↑/↓: navigate   enter: jump to session   r: refresh   q: quit
```

**Visual indicators:**
- `→` needs attention (red/yellow)
- `◉` working (blue/cyan)
- `·` idle (dim/gray)

### 4. Window Focus (macOS)

Supports multiple terminal emulators. The hook captures `$TERM_PROGRAM` to detect which terminal contains the session.

**Supported terminals:**
| Terminal | Method | Notes |
|----------|--------|-------|
| VS Code / Cursor / Codium | AppleScript + AXRaise | Focus window by project name, then Ctrl+` for terminal |
| iTerm2 | AppleScript session API | Best support - can focus specific session by ID |
| Kitty | `kitten @ focus-window` | Requires `allow_remote_control yes` in kitty.conf |
| Terminal.app | AppleScript activate | App-level focus only (limited) |
| Alacritty | App-level focus | No window-specific API |
| Warp | App-level focus | No public API |

**Editor configuration (~/.cctop/config.toml):**
```toml
[editor]
# Process name for AppleScript (as shown in Activity Monitor)
process_name = "Code"  # or "Cursor", "Code - Insiders", "Codium"

# CLI command to open projects
cli_command = "code"   # or "cursor", "code-insiders", "codium"
```

**Config defaults (if file missing or field omitted):**
- `editor.process_name` = "Code"
- `editor.cli_command` = "code"

**Config file creation:**
- TUI creates `~/.cctop/` directory on first run if missing
- Config file is optional - defaults used if not present
- Invalid TOML → log warning, use defaults

**Rust implementation (src/focus.rs):**

```rust
use std::process::Command;
use crate::session::Session;

pub fn focus_terminal(session: &Session, config: &Config) -> Result<(), Box<dyn std::error::Error>> {
    match session.terminal.program.as_str() {
        "vscode" | "cursor" => focus_editor(session, config),
        "iTerm.app" => focus_iterm(session.terminal.session_id.as_deref()),
        "kitty" => focus_kitty(session.terminal.session_id.as_deref(), &session.project_name),
        "Apple_Terminal" => focus_terminal_app(),
        _ => focus_generic(&session.project_path, config),
    }
}

fn focus_editor(session: &Session, config: &Config) -> Result<(), Box<dyn std::error::Error>> {
    let process_name = &config.editor.process_name;  // e.g., "Code", "Cursor"
    let cli_command = &config.editor.cli_command;    // e.g., "code", "cursor"
    let project_name = &session.project_name;
    let project_path = &session.project_path;

    let script = format!(r#"
        tell application "System Events" to tell process "{process_name}"
            repeat with handle in windows
                if name of handle contains "{project_name}" then
                    perform action "AXRaise" of handle
                    tell application "System Events" to set frontmost of process "{process_name}" to true
                    delay 0.1
                    key code 50 using control down  -- backtick (US keyboard; may vary)
                    return
                end if
            end repeat
        end tell
        do shell script "{cli_command} '{project_path}'"
    "#);

    Command::new("osascript").arg("-e").arg(&script).output()?;
    Ok(())
}

fn focus_iterm(session_id: Option<&str>) -> Result<(), Box<dyn std::error::Error>> {
    let script = if let Some(id) = session_id {
        format!(r#"
            tell application "iTerm"
                activate
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aSession in sessions of aTab
                            if id of aSession is "{id}" then
                                select aSession
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
        "#)
    } else {
        r#"tell application "iTerm" to activate"#.to_string()
    };

    Command::new("osascript").arg("-e").arg(&script).output()?;
    Ok(())
}

fn focus_kitty(window_id: Option<&str>, project_name: &str) -> Result<(), Box<dyn std::error::Error>> {
    let match_arg = if let Some(id) = window_id {
        format!("id:{id}")
    } else {
        format!("title:{project_name}")
    };

    Command::new("kitten")
        .args(["@", "focus-window", "--match", &match_arg])
        .output()?;
    Ok(())
}

fn focus_terminal_app() -> Result<(), Box<dyn std::error::Error>> {
    Command::new("osascript")
        .arg("-e")
        .arg(r#"tell application "Terminal" to activate"#)
        .output()?;
    Ok(())
}

fn focus_generic(project_path: &str, config: &Config) -> Result<(), Box<dyn std::error::Error>> {
    // Fallback: open in configured editor
    Command::new(&config.editor.cli_command).arg(project_path).output()?;
    Ok(())
}
```

---

## Implementation Phases

### Phase 1: Core Infrastructure
- [ ] Create Rust project with Ratatui
- [ ] Implement session file reader (poll ~/.cctop/sessions/)
- [ ] Basic TUI with flat session list
- [ ] Session model with all fields

### Phase 2: Status & Display
- [ ] Create hook binary (reads stdin, writes session JSON)
- [ ] Create CC plugin with hooks.json
- [ ] Group sessions by status in TUI
- [ ] Add status indicators (→, ◉, ·)

### Phase 3: Navigation
- [ ] Implement AppleScript window focus
- [ ] Add Enter key handler
- [ ] Fallback to configured editor CLI
- [ ] Add keyboard shortcuts (q, r, ↑/↓)

### Phase 4: Polish
- [ ] Auto-refresh every 200ms
- [ ] Stale session cleanup (see below)
- [ ] Error handling for edge cases
- [ ] Plugin packaging for CC marketplace

**Stale session cleanup:**
- On TUI startup: remove session files with `last_activity` older than 24 hours
- Reason: If CC crashes, SessionEnd hook never fires, leaving orphaned files
- 24h threshold is conservative - unlikely to have a real session that old
- TUI logs removed stale sessions for debugging

---

## Plugin Installation Flow

```
User runs: claude plugin add st0012/cctop
                    │
                    ▼
Plugin downloaded to ~/.claude/plugins/cache/...
                    │
                    ▼
SessionStart hook fires (from hooks.json)
                    │
                    ▼
Plugin's install.sh checks if `cctop` binary exists
                    │
        ┌───────────┴───────────┐
        │                       │
     exists                  missing
        │                       │
        ▼                       ▼
    continue              cargo install cctop
        │                       │
        └───────────┬───────────┘
                    │
                    ▼
cctop-hook writes session status to ~/.cctop/sessions/
```

**User workflow:**
1. `claude plugin add st0012/cctop` (one time)
2. Start Claude Code sessions as usual
3. Run `cctop` in separate terminal to monitor

---

## Distribution Strategy

**MVP:** `cargo install cctop`
- Plugin runs `cargo install cctop` on first use
- Requires Rust toolchain (you already have it)
- Avoids all macOS signing/notarization issues
- Binary builds locally, no Gatekeeper warnings

**Future options (if needed):**
- Homebrew formula for broader reach
- Pre-built signed binaries ($99/yr Developer ID)
- cargo-binstall support for faster installs

---

## Rust Crate Structure

```
cctop/
├── Cargo.toml
├── src/
│   ├── main.rs           # TUI binary entry point
│   ├── bin/
│   │   └── cctop-hook.rs # Hook binary entry point
│   ├── session.rs        # Session model + file I/O
│   ├── config.rs         # Config file parsing (~/.cctop/config.toml)
│   ├── tui.rs            # Ratatui rendering
│   ├── focus.rs          # Multi-terminal window focus (VS Code, iTerm2, Kitty, etc.)
│   └── git.rs            # Git branch detection
└── plugin/
    ├── manifest.json     # CC plugin metadata
    ├── hooks/
    │   └── hooks.json    # Hook registration
    └── scripts/
        └── install.sh    # Runs cargo install
```

---

## Verification

**Test locally:**
1. Install plugin: copy to ~/.claude/plugins/
2. Start CC session in a project
3. Run `cctop` in separate terminal
4. Verify session appears with correct status
5. Submit prompt → verify status changes
6. Press Enter → verify VS Code window focuses

---

## Open Questions Resolved

| Question | Resolution |
|----------|------------|
| CC internal state? | Use hooks - proven, accurate |
| Setup burden? | Plugin runs cargo install automatically |
| Status detection? | Hooks + 60s timeout heuristic |
| Window focus? | Multi-terminal: iTerm2 (best), Kitty, VS Code, Terminal.app |
| Last prompt? | From UserPromptSubmit hook |
| Binary distribution? | cargo install for MVP, avoids signing |

---

## References

- [claude-tmux](https://github.com/nielsgroen/claude-tmux) - Similar TUI for tmux sessions
- [Ratatui](https://ratatui.rs/) - Rust TUI framework
- [Claude HUD](https://www.vibesparking.com/en/blog/ai/claude-code/2026-01-04-claude-hud-real-time-session-monitor/) - Real-time session visibility using hooks
- [Claude Code Hooks Docs](https://code.claude.com/docs/en/hooks)
