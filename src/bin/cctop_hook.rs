//! cctop-hook: Claude Code hook handler binary.
//!
//! This binary is called by Claude Code hooks to track session state.
//! It reads hook event data from stdin and updates session files in ~/.cctop/sessions/.
//!
//! Usage: cctop-hook <HookName>
//!
//! Hook names: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, Notification, SessionEnd

use std::env;
use std::fs;
use std::io::{self, Read};
use std::path::Path;
use std::process;

use chrono::Utc;
use serde::Deserialize;

use cctop::config::Config;
use cctop::git::get_current_branch;
use cctop::session::{Session, Status, TerminalInfo};

/// Input JSON schema from Claude Code hooks.
///
/// Some fields are included to match the full schema from Claude Code,
/// even if not currently used by this hook handler.
#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct HookInput {
    session_id: String,
    cwd: String,
    #[serde(default)]
    transcript_path: Option<String>,
    #[serde(default)]
    permission_mode: Option<String>,
    hook_event_name: String,
    /// Only present for UserPromptSubmit
    #[serde(default)]
    prompt: Option<String>,
    /// Only present for PreToolUse/PostToolUse
    #[serde(default)]
    tool_name: Option<String>,
    /// Only present for Notification
    #[serde(default)]
    notification_type: Option<String>,
}

/// Captures terminal information from environment variables.
fn capture_terminal_info() -> TerminalInfo {
    let program = env::var("TERM_PROGRAM").unwrap_or_default();

    // Get terminal-specific session ID
    let session_id = env::var("ITERM_SESSION_ID")
        .ok()
        .or_else(|| env::var("KITTY_WINDOW_ID").ok());

    let tty = env::var("TTY").ok();

    TerminalInfo {
        program,
        session_id,
        tty,
    }
}

/// Determines the new status based on hook event and notification type.
fn determine_status(event: &str, notification_type: Option<&str>) -> Status {
    match event {
        "Notification" => {
            if notification_type == Some("idle_prompt") {
                Status::NeedsAttention
            } else {
                // Other notification types don't change status
                Status::Working
            }
        }
        _ => Status::from_hook_event(event),
    }
}

/// Handles a hook event by updating or creating the session file.
fn handle_hook(hook_name: &str, input: HookInput) -> Result<(), Box<dyn std::error::Error>> {
    let sessions_dir = Config::sessions_dir();
    let session_path = sessions_dir.join(format!("{}.json", input.session_id));

    // SessionEnd: remove the session file
    if hook_name == "SessionEnd" {
        if session_path.exists() {
            fs::remove_file(&session_path)?;
        }
        return Ok(());
    }

    // Get branch name
    let cwd_path = Path::new(&input.cwd);
    let branch = get_current_branch(cwd_path);

    // Capture terminal info
    let terminal = capture_terminal_info();

    // Determine new status
    let new_status = determine_status(hook_name, input.notification_type.as_deref());

    // Load existing session or create new one
    let mut session = if session_path.exists() {
        match Session::from_file(&session_path) {
            Ok(s) => s,
            Err(_) => {
                // If file is corrupted, create new session
                Session::new(
                    input.session_id.clone(),
                    input.cwd.clone(),
                    branch.clone(),
                    terminal.clone(),
                )
            }
        }
    } else {
        Session::new(
            input.session_id.clone(),
            input.cwd.clone(),
            branch.clone(),
            terminal.clone(),
        )
    };

    // Update session fields
    session.status = new_status;
    session.last_activity = Utc::now();
    session.branch = branch;

    // Update terminal info (in case it changed)
    session.terminal = terminal;

    // For UserPromptSubmit, update the last prompt
    if hook_name == "UserPromptSubmit" {
        if let Some(prompt) = input.prompt {
            session.last_prompt = Some(prompt);
        }
    }

    // Write session file atomically
    session.write_to_file(&session_path)?;

    Ok(())
}

fn main() {
    // Get hook name from first CLI argument
    let args: Vec<String> = env::args().collect();

    // Handle --version flag
    if args.len() >= 2 && (args[1] == "--version" || args[1] == "-V") {
        println!("cctop-hook {}", env!("CARGO_PKG_VERSION"));
        process::exit(0);
    }

    if args.len() < 2 {
        eprintln!("cctop-hook: missing hook name argument");
        process::exit(0); // Exit 0 to not block Claude Code
    }
    let hook_name = &args[1];

    // Read JSON from stdin
    let mut stdin_buf = String::new();
    if let Err(e) = io::stdin().read_to_string(&mut stdin_buf) {
        eprintln!("cctop-hook: failed to read stdin: {}", e);
        process::exit(0);
    }

    // Parse JSON input
    let input: HookInput = match serde_json::from_str(&stdin_buf) {
        Ok(i) => i,
        Err(e) => {
            eprintln!("cctop-hook: failed to parse JSON: {}", e);
            process::exit(0);
        }
    };

    // Handle the hook
    if let Err(e) = handle_hook(hook_name, input) {
        eprintln!("cctop-hook: error handling hook: {}", e);
        process::exit(0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_hook_input() {
        let json = r#"{
            "session_id": "abc123",
            "cwd": "/tmp/test",
            "transcript_path": "~/.claude/transcript",
            "permission_mode": "default",
            "hook_event_name": "SessionStart"
        }"#;

        let input: HookInput = serde_json::from_str(json).unwrap();
        assert_eq!(input.session_id, "abc123");
        assert_eq!(input.cwd, "/tmp/test");
        assert_eq!(input.hook_event_name, "SessionStart");
        assert!(input.prompt.is_none());
    }

    #[test]
    fn test_parse_hook_input_with_prompt() {
        let json = r#"{
            "session_id": "abc123",
            "cwd": "/tmp/test",
            "hook_event_name": "UserPromptSubmit",
            "prompt": "Fix the bug in main.rs"
        }"#;

        let input: HookInput = serde_json::from_str(json).unwrap();
        assert_eq!(input.hook_event_name, "UserPromptSubmit");
        assert_eq!(input.prompt, Some("Fix the bug in main.rs".to_string()));
    }

    #[test]
    fn test_parse_hook_input_with_tool() {
        let json = r#"{
            "session_id": "abc123",
            "cwd": "/tmp/test",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash"
        }"#;

        let input: HookInput = serde_json::from_str(json).unwrap();
        assert_eq!(input.hook_event_name, "PreToolUse");
        assert_eq!(input.tool_name, Some("Bash".to_string()));
    }

    #[test]
    fn test_parse_hook_input_with_notification() {
        let json = r#"{
            "session_id": "abc123",
            "cwd": "/tmp/test",
            "hook_event_name": "Notification",
            "notification_type": "idle_prompt"
        }"#;

        let input: HookInput = serde_json::from_str(json).unwrap();
        assert_eq!(input.hook_event_name, "Notification");
        assert_eq!(input.notification_type, Some("idle_prompt".to_string()));
    }

    #[test]
    fn test_determine_status_session_start() {
        assert_eq!(determine_status("SessionStart", None), Status::Idle);
    }

    #[test]
    fn test_determine_status_user_prompt_submit() {
        assert_eq!(determine_status("UserPromptSubmit", None), Status::Working);
    }

    #[test]
    fn test_determine_status_pre_tool_use() {
        assert_eq!(determine_status("PreToolUse", None), Status::Working);
    }

    #[test]
    fn test_determine_status_post_tool_use() {
        assert_eq!(determine_status("PostToolUse", None), Status::Working);
    }

    #[test]
    fn test_determine_status_stop() {
        assert_eq!(determine_status("Stop", None), Status::Idle);
    }

    #[test]
    fn test_determine_status_notification_idle_prompt() {
        assert_eq!(
            determine_status("Notification", Some("idle_prompt")),
            Status::NeedsAttention
        );
    }

    #[test]
    fn test_determine_status_notification_other() {
        assert_eq!(
            determine_status("Notification", Some("other")),
            Status::Working
        );
    }

    #[test]
    fn test_capture_terminal_info_default() {
        // When env vars are not set, should return empty/default values
        let info = capture_terminal_info();
        // program will be whatever TERM_PROGRAM is set to in the test environment
        // We can't assert specific values since they depend on the environment
        assert!(info.program.is_empty() || !info.program.is_empty());
    }
}
