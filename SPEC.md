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

## Testing Plan

### 1. Rust Unit Tests

**session.rs:**
```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_session_from_json() {
        let json = r#"{"session_id": "abc", "project_path": "/tmp/test", ...}"#;
        let session = Session::from_json(json).unwrap();
        assert_eq!(session.session_id, "abc");
    }

    #[test]
    fn test_session_status_display() {
        assert_eq!(Status::Working.indicator(), "◉");
        assert_eq!(Status::Idle.indicator(), "·");
        assert_eq!(Status::NeedsAttention.indicator(), "→");
    }

    #[test]
    fn test_truncate_prompt() {
        let long = "a".repeat(100);
        assert_eq!(truncate_prompt(&long, 50).len(), 50);
        assert!(truncate_prompt(&long, 50).ends_with("..."));
    }

    #[test]
    fn test_relative_time() {
        // 5 minutes ago
        let past = Utc::now() - Duration::minutes(5);
        assert_eq!(format_relative_time(past), "5m ago");
    }
}
```

**config.rs:**
```rust
#[test]
fn test_config_defaults() {
    let config = Config::default();
    assert_eq!(config.editor.process_name, "Code");
    assert_eq!(config.editor.cli_command, "code");
}

#[test]
fn test_config_from_toml() {
    let toml = r#"
        [editor]
        process_name = "Cursor"
        cli_command = "cursor"
    "#;
    let config = Config::from_toml(toml).unwrap();
    assert_eq!(config.editor.process_name, "Cursor");
}

#[test]
fn test_config_invalid_toml_uses_defaults() {
    let config = Config::from_toml("invalid { toml").unwrap_or_default();
    assert_eq!(config.editor.process_name, "Code");
}
```

**cctop-hook (bin):**
```rust
#[test]
fn test_parse_hook_stdin() {
    let json = r#"{"session_id": "abc", "cwd": "/tmp", "hook_event_name": "Stop"}"#;
    let input = HookInput::from_json(json).unwrap();
    assert_eq!(input.session_id, "abc");
}

#[test]
fn test_status_from_hook_event() {
    assert_eq!(Status::from_hook("SessionStart"), Status::Idle);
    assert_eq!(Status::from_hook("UserPromptSubmit"), Status::Working);
    assert_eq!(Status::from_hook("PreToolUse"), Status::Working);
    assert_eq!(Status::from_hook("Stop"), Status::Idle);
}

#[test]
fn test_extract_project_name() {
    assert_eq!(extract_project_name("/Users/st0012/projects/irb"), "irb");
    assert_eq!(extract_project_name("/tmp/"), "tmp");
}
```

### 2. Rust Integration Tests

**tests/session_file_io.rs:**
```rust
#[test]
fn test_write_and_read_session_file() {
    let temp_dir = tempfile::tempdir().unwrap();
    let sessions_dir = temp_dir.path().join("sessions");

    let session = Session { session_id: "test123".into(), ... };
    session.write_to_dir(&sessions_dir).unwrap();

    let sessions = Session::load_all(&sessions_dir).unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].session_id, "test123");
}

#[test]
fn test_atomic_write_creates_no_partial_files() {
    // Simulate crash during write - temp file should be cleaned up
}

#[test]
fn test_stale_session_cleanup() {
    let temp_dir = tempfile::tempdir().unwrap();
    let sessions_dir = temp_dir.path().join("sessions");

    // Create a session file with old timestamp
    let old_session = Session {
        last_activity: Utc::now() - Duration::hours(25),
        ..
    };
    old_session.write_to_dir(&sessions_dir).unwrap();

    cleanup_stale_sessions(&sessions_dir, Duration::hours(24)).unwrap();

    assert!(Session::load_all(&sessions_dir).unwrap().is_empty());
}
```

**tests/hook_e2e.rs:**
```rust
#[test]
fn test_hook_binary_processes_stdin() {
    let input = r#"{"session_id":"abc","cwd":"/tmp","hook_event_name":"SessionStart"}"#;

    let output = Command::new("cargo")
        .args(["run", "--bin", "cctop-hook", "--", "SessionStart"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();

    output.stdin.unwrap().write_all(input.as_bytes()).unwrap();
    let status = output.wait().unwrap();

    assert!(status.success());
    // Verify session file was created
}
```

### 3. Agent-Executable Tests (Claude can run these)

**After building the binaries:**

```bash
# Build
cargo build --release

# Test hook binary with mock input
echo '{"session_id":"test-123","cwd":"/tmp","hook_event_name":"SessionStart"}' | \
  ./target/release/cctop-hook SessionStart

# Verify session file created
cat ~/.cctop/sessions/test-123.json

# Test session file cleanup
./target/release/cctop --cleanup-stale

# Test TUI launches without error (non-interactive)
timeout 2 ./target/release/cctop || true  # exits after 2s

# Test config parsing
mkdir -p ~/.cctop
echo '[editor]
process_name = "TestEditor"
cli_command = "test-editor"' > ~/.cctop/config.toml
./target/release/cctop --print-config

# Run all Rust tests
cargo test

# Run with coverage (if tarpaulin installed)
cargo tarpaulin --out Html
```

### 4. Manual Tests (User only)

**These require human interaction or real CC sessions:**

| Test | Steps | Expected Result |
|------|-------|-----------------|
| **Real CC session detection** | 1. Start CC in a project<br>2. Run `cctop` | Session appears in TUI with correct repo/branch |
| **Status transitions** | 1. Submit prompt in CC<br>2. Watch cctop | Status changes: idle → working → idle |
| **Needs attention** | 1. Trigger permission prompt in CC<br>2. Watch cctop | Status shows "needs_attention" with → indicator |
| **Window focus (VS Code)** | 1. Have CC running in VS Code<br>2. Press Enter in cctop | VS Code window focuses, terminal activates |
| **Window focus (iTerm2)** | 1. Run CC in iTerm2<br>2. Press Enter in cctop | iTerm2 session focuses |
| **Window focus (Kitty)** | 1. Enable remote_control in kitty.conf<br>2. Run CC in Kitty<br>3. Press Enter in cctop | Kitty window focuses |
| **Multiple sessions** | 1. Start 3+ CC sessions<br>2. Run cctop | All sessions listed, grouped by status |
| **Cursor editor** | 1. Set config to Cursor<br>2. Run CC in Cursor<br>3. Press Enter | Cursor window focuses |
| **Session end cleanup** | 1. Exit CC session<br>2. Watch cctop | Session disappears from list |
| **CC crash recovery** | 1. Kill CC process (kill -9)<br>2. Restart cctop after 24h | Stale session file cleaned up |
| **Keyboard navigation** | 1. Run cctop<br>2. Press ↑/↓/q/r | Navigation works, q quits, r refreshes |
| **Last prompt display** | 1. Submit long prompt in CC<br>2. Check cctop | Prompt truncated to ~50-80 chars |
| **International keyboard** | 1. Use non-US keyboard<br>2. Test terminal focus | Note if Ctrl+` fails (known limitation) |

### 5. CI Pipeline (GitHub Actions)

```yaml
# .github/workflows/ci.yml
name: CI

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable

      - name: Run tests
        run: cargo test --all

      - name: Build release
        run: cargo build --release

      - name: Test hook binary
        run: |
          echo '{"session_id":"ci-test","cwd":"/tmp","hook_event_name":"SessionStart"}' | \
            ./target/release/cctop-hook SessionStart
          test -f ~/.cctop/sessions/ci-test.json

      - name: Lint
        run: cargo clippy -- -D warnings

      - name: Format check
        run: cargo fmt -- --check
```

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
