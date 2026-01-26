# cctop Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a TUI for monitoring Claude Code sessions across VS Code workspaces, showing status, context, and enabling one-keypress navigation.

**Architecture:** A Claude Code plugin writes session state via hooks to `~/.cctop/sessions/*.json`. A Ratatui TUI polls these files and displays sessions grouped by status (needs_attention, working, idle). Enter key focuses the terminal window using AppleScript/kitten commands.

**Tech Stack:** Rust, Ratatui, serde, toml, chrono

---

## Phase 1: Core Infrastructure

### Task 1: Fix Cargo.toml and Add Dependencies

**Files:**
- Modify: `Cargo.toml`

**Step 1: Update Cargo.toml with correct edition and dependencies**

```toml
[package]
name = "cctop"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "cctop"
path = "src/main.rs"

[[bin]]
name = "cctop-hook"
path = "src/bin/cctop_hook.rs"

[dependencies]
ratatui = "0.29"
crossterm = "0.28"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
toml = "0.8"
chrono = { version = "0.4", features = ["serde"] }
dirs = "5.0"
anyhow = "1.0"

[dev-dependencies]
tempfile = "3.10"
```

**Step 2: Verify it compiles**

Run: `cargo check`
Expected: Compiles with no errors (warnings OK)

**Step 3: Commit**

```bash
git add Cargo.toml
git commit -m "chore: add dependencies for cctop"
```

---

### Task 2: Create Session Model

**Files:**
- Create: `src/session.rs`
- Modify: `src/lib.rs`

**Step 1: Write the test for Session parsing**

Add to `src/lib.rs`:

```rust
pub mod session;
```

Create `src/session.rs`:

```rust
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Idle,
    Working,
    NeedsAttention,
}

impl Status {
    pub fn indicator(&self) -> &'static str {
        match self {
            Status::Idle => "·",
            Status::Working => "◉",
            Status::NeedsAttention => "→",
        }
    }

    pub fn from_hook(hook_name: &str, notification_type: Option<&str>) -> Self {
        match hook_name {
            "SessionStart" => Status::Idle,
            "UserPromptSubmit" => Status::Working,
            "PreToolUse" => Status::Working,
            "PostToolUse" => Status::Working,
            "Stop" => Status::Idle,
            "Notification" => {
                if notification_type == Some("idle_prompt") {
                    Status::NeedsAttention
                } else {
                    Status::Idle
                }
            }
            _ => Status::Idle,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Terminal {
    pub program: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tty: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub session_id: String,
    pub project_path: String,
    pub project_name: String,
    pub branch: String,
    pub status: Status,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_prompt: Option<String>,
    pub last_activity: DateTime<Utc>,
    pub started_at: DateTime<Utc>,
    pub terminal: Terminal,
}

impl Session {
    pub fn truncated_prompt(&self, max_len: usize) -> String {
        match &self.last_prompt {
            None => String::new(),
            Some(prompt) => {
                if prompt.len() <= max_len {
                    prompt.clone()
                } else {
                    format!("{}...", &prompt[..max_len - 3])
                }
            }
        }
    }
}

pub fn extract_project_name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_status_indicator() {
        assert_eq!(Status::Working.indicator(), "◉");
        assert_eq!(Status::Idle.indicator(), "·");
        assert_eq!(Status::NeedsAttention.indicator(), "→");
    }

    #[test]
    fn test_status_from_hook() {
        assert_eq!(Status::from_hook("SessionStart", None), Status::Idle);
        assert_eq!(Status::from_hook("UserPromptSubmit", None), Status::Working);
        assert_eq!(Status::from_hook("PreToolUse", None), Status::Working);
        assert_eq!(Status::from_hook("PostToolUse", None), Status::Working);
        assert_eq!(Status::from_hook("Stop", None), Status::Idle);
        assert_eq!(
            Status::from_hook("Notification", Some("idle_prompt")),
            Status::NeedsAttention
        );
        assert_eq!(
            Status::from_hook("Notification", Some("other")),
            Status::Idle
        );
    }

    #[test]
    fn test_extract_project_name() {
        assert_eq!(extract_project_name("/Users/st0012/projects/irb"), "irb");
        assert_eq!(extract_project_name("/tmp/"), "tmp");
        assert_eq!(extract_project_name("/"), "unknown");
    }

    #[test]
    fn test_truncate_prompt() {
        let session = Session {
            session_id: "test".into(),
            project_path: "/tmp/test".into(),
            project_name: "test".into(),
            branch: "main".into(),
            status: Status::Idle,
            last_prompt: Some("a".repeat(100)),
            last_activity: Utc::now(),
            started_at: Utc::now(),
            terminal: Terminal {
                program: "iTerm.app".into(),
                session_id: None,
                tty: None,
            },
        };
        let truncated = session.truncated_prompt(50);
        assert_eq!(truncated.len(), 50);
        assert!(truncated.ends_with("..."));
    }

    #[test]
    fn test_truncate_prompt_short() {
        let session = Session {
            session_id: "test".into(),
            project_path: "/tmp/test".into(),
            project_name: "test".into(),
            branch: "main".into(),
            status: Status::Idle,
            last_prompt: Some("short prompt".into()),
            last_activity: Utc::now(),
            started_at: Utc::now(),
            terminal: Terminal {
                program: "iTerm.app".into(),
                session_id: None,
                tty: None,
            },
        };
        assert_eq!(session.truncated_prompt(50), "short prompt");
    }

    #[test]
    fn test_session_json_roundtrip() {
        let session = Session {
            session_id: "abc123".into(),
            project_path: "/Users/st0012/projects/irb".into(),
            project_name: "irb".into(),
            branch: "main".into(),
            status: Status::Working,
            last_prompt: Some("Fix the bug".into()),
            last_activity: Utc::now(),
            started_at: Utc::now(),
            terminal: Terminal {
                program: "iTerm.app".into(),
                session_id: Some("w0t0p0:12345".into()),
                tty: Some("/dev/ttys003".into()),
            },
        };

        let json = serde_json::to_string(&session).unwrap();
        let parsed: Session = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed.session_id, "abc123");
        assert_eq!(parsed.status, Status::Working);
    }
}
```

**Step 2: Run tests**

Run: `cargo test session`
Expected: All tests pass

**Step 3: Commit**

```bash
git add src/session.rs src/lib.rs
git commit -m "feat: add Session model with status handling"
```

---

### Task 3: Add Session File I/O

**Files:**
- Modify: `src/session.rs`

**Step 1: Add file I/O methods to session.rs**

Add these imports at the top:

```rust
use anyhow::{Context, Result};
use std::fs;
use std::path::PathBuf;
```

Add these methods to the `impl Session` block:

```rust
impl Session {
    // ... existing methods ...

    pub fn sessions_dir() -> Result<PathBuf> {
        let home = dirs::home_dir().context("Could not find home directory")?;
        Ok(home.join(".cctop").join("sessions"))
    }

    pub fn file_path(&self) -> Result<PathBuf> {
        Ok(Self::sessions_dir()?.join(format!("{}.json", self.session_id)))
    }

    pub fn write(&self) -> Result<()> {
        let dir = Self::sessions_dir()?;
        fs::create_dir_all(&dir)?;

        let path = self.file_path()?;
        let temp_path = path.with_extension("json.tmp");

        let json = serde_json::to_string_pretty(self)?;
        fs::write(&temp_path, json)?;
        fs::rename(&temp_path, &path)?;

        Ok(())
    }

    pub fn delete(&self) -> Result<()> {
        let path = self.file_path()?;
        if path.exists() {
            fs::remove_file(path)?;
        }
        Ok(())
    }

    pub fn load_all() -> Result<Vec<Session>> {
        let dir = Self::sessions_dir()?;
        if !dir.exists() {
            return Ok(Vec::new());
        }

        let mut sessions = Vec::new();
        for entry in fs::read_dir(&dir)? {
            let entry = entry?;
            let path = entry.path();

            if path.extension().map(|e| e == "json").unwrap_or(false) {
                match fs::read_to_string(&path) {
                    Ok(content) => match serde_json::from_str::<Session>(&content) {
                        Ok(session) => sessions.push(session),
                        Err(e) => eprintln!("Failed to parse {}: {}", path.display(), e),
                    },
                    Err(e) => eprintln!("Failed to read {}: {}", path.display(), e),
                }
            }
        }

        // Sort by last_activity descending
        sessions.sort_by(|a, b| b.last_activity.cmp(&a.last_activity));

        Ok(sessions)
    }

    pub fn cleanup_stale(max_age: chrono::Duration) -> Result<usize> {
        let dir = Self::sessions_dir()?;
        if !dir.exists() {
            return Ok(0);
        }

        let cutoff = Utc::now() - max_age;
        let mut removed = 0;

        for entry in fs::read_dir(&dir)? {
            let entry = entry?;
            let path = entry.path();

            if path.extension().map(|e| e == "json").unwrap_or(false) {
                if let Ok(content) = fs::read_to_string(&path) {
                    if let Ok(session) = serde_json::from_str::<Session>(&content) {
                        if session.last_activity < cutoff {
                            if fs::remove_file(&path).is_ok() {
                                removed += 1;
                            }
                        }
                    }
                }
            }
        }

        Ok(removed)
    }
}
```

**Step 2: Add integration tests**

Add to the `#[cfg(test)]` module in `src/session.rs`:

```rust
    #[test]
    fn test_write_and_load_session() {
        // Use a unique session_id to avoid conflicts
        let session_id = format!("test-{}", std::process::id());
        let session = Session {
            session_id: session_id.clone(),
            project_path: "/tmp/test".into(),
            project_name: "test".into(),
            branch: "main".into(),
            status: Status::Idle,
            last_prompt: None,
            last_activity: Utc::now(),
            started_at: Utc::now(),
            terminal: Terminal {
                program: "test".into(),
                session_id: None,
                tty: None,
            },
        };

        // Write
        session.write().unwrap();

        // Load and verify
        let sessions = Session::load_all().unwrap();
        let found = sessions.iter().find(|s| s.session_id == session_id);
        assert!(found.is_some());

        // Cleanup
        session.delete().unwrap();
    }
```

**Step 3: Run tests**

Run: `cargo test session`
Expected: All tests pass

**Step 4: Commit**

```bash
git add src/session.rs
git commit -m "feat: add session file I/O with atomic writes"
```

---

### Task 4: Create Config Module

**Files:**
- Create: `src/config.rs`
- Modify: `src/lib.rs`

**Step 1: Create config module**

Add to `src/lib.rs`:

```rust
pub mod config;
```

Create `src/config.rs`:

```rust
use anyhow::Result;
use serde::Deserialize;
use std::fs;
use std::path::PathBuf;

#[derive(Debug, Clone, Deserialize)]
pub struct EditorConfig {
    #[serde(default = "default_process_name")]
    pub process_name: String,
    #[serde(default = "default_cli_command")]
    pub cli_command: String,
}

fn default_process_name() -> String {
    "Code".into()
}

fn default_cli_command() -> String {
    "code".into()
}

impl Default for EditorConfig {
    fn default() -> Self {
        Self {
            process_name: default_process_name(),
            cli_command: default_cli_command(),
        }
    }
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub editor: EditorConfig,
}

impl Config {
    pub fn config_path() -> Result<PathBuf> {
        let home = dirs::home_dir().ok_or_else(|| anyhow::anyhow!("No home directory"))?;
        Ok(home.join(".cctop").join("config.toml"))
    }

    pub fn load() -> Self {
        let path = match Self::config_path() {
            Ok(p) => p,
            Err(_) => return Self::default(),
        };

        if !path.exists() {
            return Self::default();
        }

        match fs::read_to_string(&path) {
            Ok(content) => toml::from_str(&content).unwrap_or_else(|e| {
                eprintln!("Warning: Invalid config file: {}", e);
                Self::default()
            }),
            Err(_) => Self::default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let config: Config = toml::from_str(toml).unwrap();
        assert_eq!(config.editor.process_name, "Cursor");
        assert_eq!(config.editor.cli_command, "cursor");
    }

    #[test]
    fn test_config_partial_toml() {
        let toml = r#"
            [editor]
            process_name = "Cursor"
        "#;
        let config: Config = toml::from_str(toml).unwrap();
        assert_eq!(config.editor.process_name, "Cursor");
        assert_eq!(config.editor.cli_command, "code"); // default
    }

    #[test]
    fn test_config_empty_toml() {
        let config: Config = toml::from_str("").unwrap();
        assert_eq!(config.editor.process_name, "Code");
        assert_eq!(config.editor.cli_command, "code");
    }
}
```

**Step 2: Run tests**

Run: `cargo test config`
Expected: All tests pass

**Step 3: Commit**

```bash
git add src/config.rs src/lib.rs
git commit -m "feat: add config module with TOML parsing"
```

---

### Task 5: Create Git Module

**Files:**
- Create: `src/git.rs`
- Modify: `src/lib.rs`

**Step 1: Create git module**

Add to `src/lib.rs`:

```rust
pub mod git;
```

Create `src/git.rs`:

```rust
use std::path::Path;
use std::process::Command;

pub fn get_branch(cwd: &Path) -> String {
    Command::new("git")
        .args(["branch", "--show-current"])
        .current_dir(cwd)
        .output()
        .ok()
        .and_then(|output| {
            if output.status.success() {
                String::from_utf8(output.stdout)
                    .ok()
                    .map(|s| s.trim().to_string())
            } else {
                None
            }
        })
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    #[test]
    fn test_get_branch_in_git_repo() {
        // This test runs in a git repo
        let cwd = env::current_dir().unwrap();
        let branch = get_branch(&cwd);
        // Should get a real branch name, not "unknown"
        assert!(!branch.is_empty());
        assert_ne!(branch, "unknown");
    }

    #[test]
    fn test_get_branch_outside_repo() {
        let branch = get_branch(Path::new("/tmp"));
        assert_eq!(branch, "unknown");
    }
}
```

**Step 2: Run tests**

Run: `cargo test git`
Expected: All tests pass

**Step 3: Commit**

```bash
git add src/git.rs src/lib.rs
git commit -m "feat: add git branch detection"
```

---

### Task 6: Create Focus Module

**Files:**
- Create: `src/focus.rs`
- Modify: `src/lib.rs`

**Step 1: Create focus module**

Add to `src/lib.rs`:

```rust
pub mod focus;
```

Create `src/focus.rs`:

```rust
use crate::config::Config;
use crate::session::Session;
use anyhow::Result;
use std::process::Command;

pub fn focus_terminal(session: &Session, config: &Config) -> Result<()> {
    match session.terminal.program.as_str() {
        "vscode" | "Code" | "cursor" | "Cursor" => focus_editor(session, config),
        "iTerm.app" => focus_iterm(session.terminal.session_id.as_deref()),
        "kitty" => focus_kitty(session.terminal.session_id.as_deref(), &session.project_name),
        "Apple_Terminal" => focus_terminal_app(),
        _ => focus_generic(&session.project_path, config),
    }
}

fn focus_editor(session: &Session, config: &Config) -> Result<()> {
    let process_name = &config.editor.process_name;
    let cli_command = &config.editor.cli_command;
    let project_name = &session.project_name;
    let project_path = &session.project_path;

    let script = format!(
        r#"
        tell application "System Events" to tell process "{process_name}"
            repeat with handle in windows
                if name of handle contains "{project_name}" then
                    perform action "AXRaise" of handle
                    tell application "System Events" to set frontmost of process "{process_name}" to true
                    delay 0.1
                    key code 50 using control down
                    return
                end if
            end repeat
        end tell
        do shell script "{cli_command} '{project_path}'"
    "#
    );

    Command::new("osascript")
        .arg("-e")
        .arg(&script)
        .output()?;

    Ok(())
}

fn focus_iterm(session_id: Option<&str>) -> Result<()> {
    let script = if let Some(id) = session_id {
        format!(
            r#"
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
        "#
        )
    } else {
        r#"tell application "iTerm" to activate"#.to_string()
    };

    Command::new("osascript")
        .arg("-e")
        .arg(&script)
        .output()?;

    Ok(())
}

fn focus_kitty(window_id: Option<&str>, project_name: &str) -> Result<()> {
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

fn focus_terminal_app() -> Result<()> {
    Command::new("osascript")
        .arg("-e")
        .arg(r#"tell application "Terminal" to activate"#)
        .output()?;

    Ok(())
}

fn focus_generic(project_path: &str, config: &Config) -> Result<()> {
    Command::new(&config.editor.cli_command)
        .arg(project_path)
        .output()?;

    Ok(())
}

#[cfg(test)]
mod tests {
    // Focus tests require manual verification since they involve UI
    // See testing plan in SPEC.md for manual test cases
}
```

**Step 2: Verify it compiles**

Run: `cargo check`
Expected: No errors

**Step 3: Commit**

```bash
git add src/focus.rs src/lib.rs
git commit -m "feat: add multi-terminal window focus support"
```

---

### Task 7: Create Time Formatting Utility

**Files:**
- Modify: `src/session.rs`

**Step 1: Add relative time formatting**

Add this function to `src/session.rs` (after the `extract_project_name` function):

```rust
pub fn format_relative_time(time: DateTime<Utc>) -> String {
    let now = Utc::now();
    let duration = now.signed_duration_since(time);

    if duration.num_seconds() < 0 {
        return "just now".into();
    }

    let seconds = duration.num_seconds();
    let minutes = duration.num_minutes();
    let hours = duration.num_hours();
    let days = duration.num_days();

    if seconds < 60 {
        format!("{}s ago", seconds)
    } else if minutes < 60 {
        format!("{}m ago", minutes)
    } else if hours < 24 {
        format!("{}h ago", hours)
    } else {
        format!("{}d ago", days)
    }
}
```

Add test to the `#[cfg(test)]` module:

```rust
    #[test]
    fn test_format_relative_time() {
        use chrono::Duration;

        let now = Utc::now();

        assert_eq!(format_relative_time(now - Duration::seconds(30)), "30s ago");
        assert_eq!(format_relative_time(now - Duration::minutes(5)), "5m ago");
        assert_eq!(format_relative_time(now - Duration::hours(2)), "2h ago");
        assert_eq!(format_relative_time(now - Duration::days(3)), "3d ago");
    }
```

**Step 2: Run tests**

Run: `cargo test format_relative`
Expected: Test passes

**Step 3: Commit**

```bash
git add src/session.rs
git commit -m "feat: add relative time formatting"
```

---

## Phase 2: Hook Binary

### Task 8: Create Hook Binary

**Files:**
- Create: `src/bin/cctop_hook.rs`

**Step 1: Create the hook binary**

Create `src/bin/cctop_hook.rs`:

```rust
use anyhow::{Context, Result};
use chrono::Utc;
use cctop::git::get_branch;
use cctop::session::{extract_project_name, Session, Status, Terminal};
use serde::Deserialize;
use std::env;
use std::io::{self, Read};
use std::path::Path;

#[derive(Debug, Deserialize)]
struct HookInput {
    session_id: String,
    cwd: String,
    #[serde(default)]
    prompt: Option<String>,
    #[serde(default)]
    notification_type: Option<String>,
}

fn main() {
    if let Err(e) = run() {
        eprintln!("cctop-hook error: {}", e);
        // Don't exit with error - we don't want to block Claude Code
    }
}

fn run() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    let hook_name = args.get(1).context("Missing hook name argument")?;

    let mut stdin = String::new();
    io::stdin().read_to_string(&mut stdin)?;

    let input: HookInput = serde_json::from_str(&stdin)
        .context("Failed to parse hook input JSON")?;

    match hook_name.as_str() {
        "SessionEnd" => {
            // Delete the session file
            let session = Session {
                session_id: input.session_id,
                project_path: String::new(),
                project_name: String::new(),
                branch: String::new(),
                status: Status::Idle,
                last_prompt: None,
                last_activity: Utc::now(),
                started_at: Utc::now(),
                terminal: Terminal {
                    program: String::new(),
                    session_id: None,
                    tty: None,
                },
            };
            session.delete()?;
        }
        _ => {
            // Create or update session file
            let cwd_path = Path::new(&input.cwd);
            let branch = get_branch(cwd_path);
            let project_name = extract_project_name(&input.cwd);
            let terminal = detect_terminal();
            let status = Status::from_hook(hook_name, input.notification_type.as_deref());

            // Try to load existing session to preserve started_at and last_prompt
            let (started_at, last_prompt) = load_existing_session_data(&input.session_id);

            let last_prompt = if hook_name == "UserPromptSubmit" {
                input.prompt
            } else {
                last_prompt
            };

            let session = Session {
                session_id: input.session_id,
                project_path: input.cwd,
                project_name,
                branch,
                status,
                last_prompt,
                last_activity: Utc::now(),
                started_at: started_at.unwrap_or_else(Utc::now),
                terminal,
            };

            session.write()?;
        }
    }

    Ok(())
}

fn detect_terminal() -> Terminal {
    let program = env::var("TERM_PROGRAM").unwrap_or_else(|_| "unknown".into());

    let session_id = env::var("ITERM_SESSION_ID")
        .ok()
        .or_else(|| env::var("KITTY_WINDOW_ID").ok());

    let tty = env::var("TTY").ok();

    Terminal {
        program,
        session_id,
        tty,
    }
}

fn load_existing_session_data(
    session_id: &str,
) -> (Option<chrono::DateTime<Utc>>, Option<String>) {
    let sessions = Session::load_all().unwrap_or_default();
    sessions
        .into_iter()
        .find(|s| s.session_id == session_id)
        .map(|s| (Some(s.started_at), s.last_prompt))
        .unwrap_or((None, None))
}
```

**Step 2: Build and verify**

Run: `cargo build --bin cctop-hook`
Expected: Binary compiles successfully

**Step 3: Test with mock input**

Run:
```bash
echo '{"session_id":"test-hook-123","cwd":"/tmp","hook_event_name":"SessionStart"}' | ./target/debug/cctop-hook SessionStart
cat ~/.cctop/sessions/test-hook-123.json
```
Expected: Session file created with correct data

**Step 4: Cleanup test file**

Run: `rm ~/.cctop/sessions/test-hook-123.json`

**Step 5: Commit**

```bash
git add src/bin/cctop_hook.rs
git commit -m "feat: add cctop-hook binary for CC integration"
```

---

## Phase 3: TUI

### Task 9: Create TUI Module

**Files:**
- Create: `src/tui.rs`
- Modify: `src/lib.rs`

**Step 1: Create the TUI module**

Add to `src/lib.rs`:

```rust
pub mod tui;
```

Create `src/tui.rs`:

```rust
use crate::config::Config;
use crate::focus::focus_terminal;
use crate::session::{format_relative_time, Session, Status};
use anyhow::Result;
use crossterm::{
    event::{self, Event, KeyCode, KeyEventKind},
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
    ExecutableCommand,
};
use ratatui::{
    prelude::*,
    widgets::{Block, Borders, List, ListItem, ListState, Paragraph},
};
use std::io::stdout;
use std::time::Duration;

pub struct App {
    sessions: Vec<Session>,
    list_state: ListState,
    config: Config,
    should_quit: bool,
}

impl App {
    pub fn new() -> Self {
        let mut list_state = ListState::default();
        list_state.select(Some(0));

        Self {
            sessions: Vec::new(),
            list_state,
            config: Config::load(),
            should_quit: false,
        }
    }

    pub fn run(&mut self) -> Result<()> {
        // Cleanup stale sessions on startup
        let _ = Session::cleanup_stale(chrono::Duration::hours(24));

        stdout().execute(EnterAlternateScreen)?;
        enable_raw_mode()?;

        let mut terminal = Terminal::new(CrosstermBackend::new(stdout()))?;
        terminal.clear()?;

        while !self.should_quit {
            self.refresh_sessions();
            terminal.draw(|frame| self.render(frame))?;

            if event::poll(Duration::from_millis(200))? {
                if let Event::Key(key) = event::read()? {
                    if key.kind == KeyEventKind::Press {
                        self.handle_key(key.code);
                    }
                }
            }
        }

        stdout().execute(LeaveAlternateScreen)?;
        disable_raw_mode()?;

        Ok(())
    }

    fn refresh_sessions(&mut self) {
        self.sessions = Session::load_all().unwrap_or_default();

        // Sort by status priority, then by last_activity
        self.sessions.sort_by(|a, b| {
            let priority = |s: &Status| match s {
                Status::NeedsAttention => 0,
                Status::Working => 1,
                Status::Idle => 2,
            };
            priority(&a.status)
                .cmp(&priority(&b.status))
                .then_with(|| b.last_activity.cmp(&a.last_activity))
        });

        // Ensure selection stays valid
        if let Some(selected) = self.list_state.selected() {
            if selected >= self.sessions.len() && !self.sessions.is_empty() {
                self.list_state.select(Some(self.sessions.len() - 1));
            }
        }
    }

    fn handle_key(&mut self, key: KeyCode) {
        match key {
            KeyCode::Char('q') | KeyCode::Esc => self.should_quit = true,
            KeyCode::Char('r') => self.refresh_sessions(),
            KeyCode::Up | KeyCode::Char('k') => self.select_previous(),
            KeyCode::Down | KeyCode::Char('j') => self.select_next(),
            KeyCode::Enter => self.focus_selected(),
            _ => {}
        }
    }

    fn select_previous(&mut self) {
        if self.sessions.is_empty() {
            return;
        }
        let i = match self.list_state.selected() {
            Some(i) => {
                if i == 0 {
                    self.sessions.len() - 1
                } else {
                    i - 1
                }
            }
            None => 0,
        };
        self.list_state.select(Some(i));
    }

    fn select_next(&mut self) {
        if self.sessions.is_empty() {
            return;
        }
        let i = match self.list_state.selected() {
            Some(i) => {
                if i >= self.sessions.len() - 1 {
                    0
                } else {
                    i + 1
                }
            }
            None => 0,
        };
        self.list_state.select(Some(i));
    }

    fn focus_selected(&mut self) {
        if let Some(i) = self.list_state.selected() {
            if let Some(session) = self.sessions.get(i) {
                let _ = focus_terminal(session, &self.config);
            }
        }
    }

    fn render(&mut self, frame: &mut Frame) {
        let area = frame.area();

        // Layout: header, content, footer
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3), // header
                Constraint::Min(5),    // content
                Constraint::Length(1), // footer
            ])
            .split(area);

        self.render_header(frame, chunks[0]);
        self.render_sessions(frame, chunks[1]);
        self.render_footer(frame, chunks[2]);
    }

    fn render_header(&self, frame: &mut Frame, area: Rect) {
        let session_count = self.sessions.len();
        let title = format!(
            "  cctop{:>width$}",
            format!("{} sessions  ", session_count),
            width = (area.width as usize).saturating_sub(10)
        );

        let header = Paragraph::new(title)
            .style(Style::default().fg(Color::White).bold())
            .block(Block::default().borders(Borders::ALL));

        frame.render_widget(header, area);
    }

    fn render_sessions(&mut self, frame: &mut Frame, area: Rect) {
        if self.sessions.is_empty() {
            let msg = Paragraph::new("No active sessions\n\nStart a Claude Code session to see it here.")
                .style(Style::default().fg(Color::DarkGray))
                .alignment(Alignment::Center);
            frame.render_widget(msg, area);
            return;
        }

        let items: Vec<ListItem> = self
            .sessions
            .iter()
            .map(|s| self.session_to_list_item(s, area.width))
            .collect();

        let list = List::new(items)
            .highlight_style(Style::default().add_modifier(Modifier::REVERSED))
            .highlight_symbol("> ");

        frame.render_stateful_widget(list, area, &mut self.list_state);
    }

    fn session_to_list_item(&self, session: &Session, width: u16) -> ListItem {
        let (indicator, color) = match session.status {
            Status::NeedsAttention => ("→", Color::Yellow),
            Status::Working => ("◉", Color::Cyan),
            Status::Idle => ("·", Color::DarkGray),
        };

        let time = format_relative_time(session.last_activity);

        // Format: indicator project_name branch time
        let main_line = format!(
            "{} {:<20} {:<15} {}",
            indicator, session.project_name, session.branch, time
        );

        let prompt_line = if let Some(prompt) = &session.last_prompt {
            let max_width = (width as usize).saturating_sub(6);
            let truncated = session.truncated_prompt(max_width.min(60));
            format!("    \"{}\"", truncated)
        } else {
            String::new()
        };

        let content = if prompt_line.is_empty() {
            main_line
        } else {
            format!("{}\n{}", main_line, prompt_line)
        };

        ListItem::new(content).style(Style::default().fg(color))
    }

    fn render_footer(&self, frame: &mut Frame, area: Rect) {
        let footer = Paragraph::new("  ↑/↓: navigate   enter: jump to session   r: refresh   q: quit")
            .style(Style::default().fg(Color::DarkGray));
        frame.render_widget(footer, area);
    }
}
```

**Step 2: Verify it compiles**

Run: `cargo check`
Expected: No errors

**Step 3: Commit**

```bash
git add src/tui.rs src/lib.rs
git commit -m "feat: add TUI with session list and keyboard navigation"
```

---

### Task 10: Create Main Binary

**Files:**
- Create: `src/main.rs`
- Remove: old `src/lib.rs` test code

**Step 1: Update lib.rs to only export modules**

Replace `src/lib.rs` with:

```rust
pub mod config;
pub mod focus;
pub mod git;
pub mod session;
pub mod tui;
```

**Step 2: Create main.rs**

Create `src/main.rs`:

```rust
use anyhow::Result;
use cctop::tui::App;

fn main() -> Result<()> {
    let mut app = App::new();
    app.run()
}
```

**Step 3: Build and test**

Run: `cargo build`
Expected: Compiles successfully

Run: `cargo run` (then press 'q' to quit)
Expected: TUI launches and displays (possibly empty) session list

**Step 4: Commit**

```bash
git add src/main.rs src/lib.rs
git commit -m "feat: add main binary entry point"
```

---

## Phase 4: Plugin

### Task 11: Create CC Plugin Structure

**Files:**
- Create: `plugin/manifest.json`
- Create: `plugin/hooks/hooks.json`
- Create: `plugin/scripts/install.sh`

**Step 1: Create plugin directory structure**

```bash
mkdir -p plugin/hooks plugin/scripts
```

**Step 2: Create manifest.json**

Create `plugin/manifest.json`:

```json
{
  "name": "cctop",
  "version": "0.1.0",
  "description": "Monitor Claude Code sessions across workspaces",
  "author": "st0012",
  "repository": "https://github.com/st0012/cctop"
}
```

**Step 3: Create hooks.json**

Create `plugin/hooks/hooks.json`:

```json
{
  "hooks": [
    {
      "event": "SessionStart",
      "hooks": [
        {
          "type": "command",
          "command": "cctop-hook SessionStart"
        }
      ]
    },
    {
      "event": "UserPromptSubmit",
      "hooks": [
        {
          "type": "command",
          "command": "cctop-hook UserPromptSubmit"
        }
      ]
    },
    {
      "event": "PreToolUse",
      "hooks": [
        {
          "type": "command",
          "command": "cctop-hook PreToolUse"
        }
      ]
    },
    {
      "event": "PostToolUse",
      "hooks": [
        {
          "type": "command",
          "command": "cctop-hook PostToolUse"
        }
      ]
    },
    {
      "event": "Stop",
      "hooks": [
        {
          "type": "command",
          "command": "cctop-hook Stop"
        }
      ]
    },
    {
      "event": "Notification",
      "hooks": [
        {
          "type": "command",
          "command": "cctop-hook Notification"
        }
      ]
    },
    {
      "event": "SessionEnd",
      "hooks": [
        {
          "type": "command",
          "command": "cctop-hook SessionEnd"
        }
      ]
    }
  ]
}
```

**Step 4: Create install.sh**

Create `plugin/scripts/install.sh`:

```bash
#!/bin/bash
set -e

# Check if cctop is already installed
if command -v cctop-hook &> /dev/null; then
    echo "cctop is already installed"
    exit 0
fi

# Check if cargo is available
if ! command -v cargo &> /dev/null; then
    echo "Error: Rust toolchain not found. Please install from https://rustup.rs/"
    exit 1
fi

# Install cctop from crates.io (or local if developing)
echo "Installing cctop..."
cargo install cctop

echo "cctop installed successfully!"
echo "Run 'cctop' in a separate terminal to monitor your Claude Code sessions."
```

Make it executable:

```bash
chmod +x plugin/scripts/install.sh
```

**Step 5: Commit**

```bash
git add plugin/
git commit -m "feat: add Claude Code plugin structure"
```

---

### Task 12: Add .gitignore Updates

**Files:**
- Modify: `.gitignore`

**Step 1: Update .gitignore**

Replace `.gitignore` content:

```
/target
Cargo.lock
.DS_Store
*.swp
*.swo
*~
```

**Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: update gitignore"
```

---

### Task 13: Run Full Test Suite

**Files:** None (verification only)

**Step 1: Run all tests**

Run: `cargo test`
Expected: All tests pass

**Step 2: Run clippy**

Run: `cargo clippy -- -D warnings`
Expected: No warnings

**Step 3: Check formatting**

Run: `cargo fmt -- --check`
Expected: No formatting issues (or run `cargo fmt` to fix)

**Step 4: Build release**

Run: `cargo build --release`
Expected: Compiles successfully

**Step 5: Manual smoke test**

Run: `./target/release/cctop`
Expected: TUI launches, shows "No active sessions", quit with 'q'

---

### Task 14: Final Integration Test

**Step 1: Test hook binary with real-ish data**

```bash
# Simulate SessionStart
echo '{"session_id":"integration-test","cwd":"/Users/st0012/projects/irb"}' | ./target/release/cctop-hook SessionStart

# Verify file created
cat ~/.cctop/sessions/integration-test.json

# Simulate UserPromptSubmit
echo '{"session_id":"integration-test","cwd":"/Users/st0012/projects/irb","prompt":"Fix the bug in completion"}' | ./target/release/cctop-hook UserPromptSubmit

# Verify prompt saved
cat ~/.cctop/sessions/integration-test.json

# Launch TUI - should show the session
./target/release/cctop &
TUI_PID=$!
sleep 2
kill $TUI_PID 2>/dev/null || true

# Cleanup
echo '{"session_id":"integration-test","cwd":"/Users/st0012/projects/irb"}' | ./target/release/cctop-hook SessionEnd

# Verify file removed
ls ~/.cctop/sessions/integration-test.json 2>/dev/null && echo "ERROR: file still exists" || echo "OK: file cleaned up"
```

Expected: All steps succeed, file created/updated/deleted correctly

---

## Summary

After completing all tasks, you will have:

1. **Rust crate** with:
   - `cctop` binary (TUI)
   - `cctop-hook` binary (hook handler)
   - Modules: session, config, git, focus, tui

2. **CC Plugin** with:
   - Hook registration for all lifecycle events
   - Install script for cargo install

3. **Functionality**:
   - Session tracking via hooks
   - Status display (needs_attention, working, idle)
   - Keyboard navigation
   - Multi-terminal window focus
   - Stale session cleanup

To use:
1. `cargo install --path .` to install binaries
2. Copy plugin to CC plugins directory (or publish)
3. Run `cctop` in a separate terminal
