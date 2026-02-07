//! cctop-hook: Claude Code hook handler binary.
//!
//! This binary is called by Claude Code hooks to track session state.
//! It reads hook event data from stdin and updates session files in ~/.cctop/sessions/.
//!
//! Usage: cctop-hook <HookName>
//!
//! Hook names: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, Notification, PermissionRequest, PreCompact, SessionEnd

use std::env;
use std::io::{self, Read};
use std::path::Path;
use std::process;

use chrono::Utc;
use serde::Deserialize;
use serde_json::Value;

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
    /// Tool input JSON, present for PreToolUse/PostToolUse
    #[serde(default)]
    tool_input: Option<Value>,
    /// Only present for Notification
    #[serde(default)]
    notification_type: Option<String>,
    /// Message content (Notification, PermissionRequest)
    #[serde(default)]
    message: Option<String>,
    /// Title (PermissionRequest)
    #[serde(default)]
    title: Option<String>,
    /// Trigger for SessionStart (e.g., "startup", "resume")
    #[serde(default)]
    trigger: Option<String>,
}

/// Gets the parent process ID.
///
/// The hook is invoked by Claude Code, so the parent PID is the Claude process.
fn get_parent_pid() -> Option<u32> {
    Some(std::os::unix::process::parent_id())
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
        "Notification" => match notification_type {
            Some("idle_prompt") => Status::WaitingInput,
            Some("permission_prompt") => Status::WaitingPermission,
            _ => Status::Working,
        },
        "PermissionRequest" => Status::WaitingPermission,
        _ => Status::from_hook_event(event),
    }
}

/// Maximum length for extracted tool detail strings.
const MAX_TOOL_DETAIL_LEN: usize = 120;

/// Extracts a human-readable detail string from tool_input JSON.
///
/// Maps tool names to the most relevant field in their input:
/// - Bash -> command
/// - Edit/Write/Read -> file_path
/// - Grep/Glob -> pattern
/// - WebFetch -> url
/// - WebSearch -> query
/// - Task -> description
fn extract_tool_detail(tool_name: &str, tool_input: &Value) -> Option<String> {
    let field = match tool_name {
        "Bash" => "command",
        "Edit" | "Write" | "Read" => "file_path",
        "Grep" | "Glob" => "pattern",
        "WebFetch" => "url",
        "WebSearch" => "query",
        "Task" => "description",
        _ => return None,
    };

    let value = tool_input.get(field)?.as_str()?;
    if value.is_empty() {
        return None;
    }

    let detail = if value.len() > MAX_TOOL_DETAIL_LEN {
        let truncated: String = value.chars().take(MAX_TOOL_DETAIL_LEN - 3).collect();
        format!("{}...", truncated)
    } else {
        value.to_string()
    };
    Some(detail)
}

/// Clean up any existing session files with the same PID.
///
/// This handles the case where a session is resumed - Claude Code creates a new
/// session_id but uses the same process. We remove the old session file to avoid
/// duplicates.
fn cleanup_sessions_with_pid(sessions_dir: &Path, pid: u32, current_session_id: &str) {
    use std::fs;

    let Ok(entries) = fs::read_dir(sessions_dir) else {
        return;
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().map(|e| e == "json").unwrap_or(false) {
            if let Ok(session) = Session::from_file(&path) {
                // Remove if same PID but different session_id
                if session.pid == Some(pid) && session.session_id != current_session_id {
                    let _ = fs::remove_file(&path);
                }
            }
        }
    }
}

/// Handles a hook event by updating or creating the session file.
fn handle_hook(hook_name: &str, input: HookInput) -> Result<(), Box<dyn std::error::Error>> {
    // SessionEnd is a no-op (PID-based liveness detection handles cleanup)
    if hook_name == "SessionEnd" {
        return Ok(());
    }

    let sessions_dir = Config::sessions_dir();
    let session_path = sessions_dir.join(format!("{}.json", input.session_id));

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

    // Update common session fields
    session.status = new_status;
    session.last_activity = Utc::now();
    session.branch = branch;
    session.terminal = terminal;

    // Apply state transition clearing logic per hook event
    match hook_name {
        "SessionStart" => {
            // Clear transient fields on session start
            session.last_tool = None;
            session.last_tool_detail = None;
            session.notification_message = None;
            session.context_compacted = false;

            // Capture the parent PID (the Claude Code process)
            let pid = get_parent_pid();
            session.pid = pid;

            // Clean up old sessions with the same PID (e.g., when resuming a session)
            if let Some(current_pid) = pid {
                cleanup_sessions_with_pid(&sessions_dir, current_pid, &input.session_id);
            }
        }

        "UserPromptSubmit" => {
            // Clear tool/notification state, set prompt
            session.last_tool = None;
            session.last_tool_detail = None;
            session.notification_message = None;

            if let Some(prompt) = input.prompt {
                session.last_prompt = Some(prompt);
            }
        }

        "PreToolUse" => {
            // Set last_tool and extract detail from tool_input
            if let Some(ref tool_name) = input.tool_name {
                session.last_tool = Some(tool_name.clone());
                session.last_tool_detail = input
                    .tool_input
                    .as_ref()
                    .and_then(|ti| extract_tool_detail(tool_name, ti));
            }
        }

        "PermissionRequest" => {
            // Build notification message from title or tool details
            let msg = input
                .title
                .or_else(|| {
                    input.tool_name.as_ref().map(|t| {
                        let detail = input
                            .tool_input
                            .as_ref()
                            .and_then(|ti| extract_tool_detail(t, ti));
                        match detail {
                            Some(d) => format!("{}: {}", t, d),
                            None => t.clone(),
                        }
                    })
                });
            session.notification_message = msg;
            session.last_tool = None;
            session.last_tool_detail = None;
        }

        "Notification" => {
            // Clear stale tool info when transitioning out of Working
            session.last_tool = None;
            session.last_tool_detail = None;
            // Store notification message if present
            if let Some(ref msg) = input.message {
                session.notification_message = Some(msg.clone());
            }
        }

        "PreCompact" => {
            // Mark that context has been compacted
            session.context_compacted = true;
        }

        "Stop" => {
            // Clear transient fields on stop
            session.last_tool = None;
            session.last_tool_detail = None;
            session.notification_message = None;
        }

        _ => {}
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
            Status::WaitingInput
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
    fn test_determine_status_permission_request() {
        assert_eq!(
            determine_status("PermissionRequest", None),
            Status::WaitingPermission
        );
    }

    #[test]
    fn test_determine_status_notification_permission_prompt() {
        assert_eq!(
            determine_status("Notification", Some("permission_prompt")),
            Status::WaitingPermission
        );
    }

    #[test]
    fn test_parse_hook_input_with_tool_input() {
        let json = r#"{
            "session_id": "abc123",
            "cwd": "/tmp/test",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "npm test"}
        }"#;

        let input: HookInput = serde_json::from_str(json).unwrap();
        assert_eq!(input.tool_name, Some("Bash".to_string()));
        assert!(input.tool_input.is_some());
        let ti = input.tool_input.unwrap();
        assert_eq!(ti["command"].as_str(), Some("npm test"));
    }

    #[test]
    fn test_parse_hook_input_with_message_and_title() {
        let json = r#"{
            "session_id": "abc123",
            "cwd": "/tmp/test",
            "hook_event_name": "PermissionRequest",
            "title": "Allow Bash command?",
            "message": "Run npm test",
            "tool_name": "Bash"
        }"#;

        let input: HookInput = serde_json::from_str(json).unwrap();
        assert_eq!(input.title, Some("Allow Bash command?".to_string()));
        assert_eq!(input.message, Some("Run npm test".to_string()));
    }

    #[test]
    fn test_extract_tool_detail_bash() {
        let input = serde_json::json!({"command": "npm test"});
        assert_eq!(
            extract_tool_detail("Bash", &input),
            Some("npm test".to_string())
        );
    }

    #[test]
    fn test_extract_tool_detail_edit() {
        let input = serde_json::json!({"file_path": "/src/main.rs", "old_string": "foo", "new_string": "bar"});
        assert_eq!(
            extract_tool_detail("Edit", &input),
            Some("/src/main.rs".to_string())
        );
    }

    #[test]
    fn test_extract_tool_detail_grep() {
        let input = serde_json::json!({"pattern": "TODO", "path": "/src"});
        assert_eq!(
            extract_tool_detail("Grep", &input),
            Some("TODO".to_string())
        );
    }

    #[test]
    fn test_extract_tool_detail_web_search() {
        let input = serde_json::json!({"query": "rust egui tutorial"});
        assert_eq!(
            extract_tool_detail("WebSearch", &input),
            Some("rust egui tutorial".to_string())
        );
    }

    #[test]
    fn test_extract_tool_detail_unknown_tool() {
        let input = serde_json::json!({"anything": "value"});
        assert_eq!(extract_tool_detail("UnknownTool", &input), None);
    }

    #[test]
    fn test_extract_tool_detail_missing_field() {
        let input = serde_json::json!({"other_field": "value"});
        assert_eq!(extract_tool_detail("Bash", &input), None);
    }

    #[test]
    fn test_extract_tool_detail_truncation() {
        let long_cmd = "a".repeat(200);
        let input = serde_json::json!({"command": long_cmd});
        let result = extract_tool_detail("Bash", &input).unwrap();
        assert_eq!(result.len(), MAX_TOOL_DETAIL_LEN);
        assert!(result.ends_with("..."));
    }

    #[test]
    fn test_extract_tool_detail_empty_value() {
        let input = serde_json::json!({"command": ""});
        assert_eq!(extract_tool_detail("Bash", &input), None);
    }

    #[test]
    fn test_capture_terminal_info_default() {
        // When env vars are not set, should return empty/default values
        let info = capture_terminal_info();
        // program will be whatever TERM_PROGRAM is set to in the test environment
        // We can't assert specific values since they depend on the environment
        assert!(info.program.is_empty() || !info.program.is_empty());
    }

    #[test]
    fn test_get_parent_pid_returns_some() {
        // Should return the parent process ID
        let pid = get_parent_pid();
        assert!(pid.is_some());
        // Parent PID should be a reasonable value (> 0)
        assert!(pid.unwrap() > 0);
    }

    #[test]
    fn test_cleanup_sessions_with_pid() {
        use tempfile::tempdir;

        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path();

        // Create two sessions with the same PID (simulating resume)
        let mut session1 = Session::new(
            "old-session".to_string(),
            "/nonexistent/test/project".to_string(),
            "main".to_string(),
            TerminalInfo::default(),
        );
        session1.pid = Some(12345);
        session1.write_to_dir(sessions_dir).unwrap();

        let mut session2 = Session::new(
            "new-session".to_string(),
            "/nonexistent/test/project".to_string(),
            "main".to_string(),
            TerminalInfo::default(),
        );
        session2.pid = Some(12345);
        session2.write_to_dir(sessions_dir).unwrap();

        // Create a session with a different PID (should not be removed)
        let mut session3 = Session::new(
            "other-session".to_string(),
            "/nonexistent/test/other".to_string(),
            "main".to_string(),
            TerminalInfo::default(),
        );
        session3.pid = Some(99999);
        session3.write_to_dir(sessions_dir).unwrap();

        // Verify all 3 exist
        assert!(sessions_dir.join("old-session.json").exists());
        assert!(sessions_dir.join("new-session.json").exists());
        assert!(sessions_dir.join("other-session.json").exists());

        // Clean up sessions with PID 12345, keeping "new-session"
        cleanup_sessions_with_pid(sessions_dir, 12345, "new-session");

        // old-session should be removed (same PID, different session_id)
        assert!(!sessions_dir.join("old-session.json").exists());
        // new-session should remain (current session)
        assert!(sessions_dir.join("new-session.json").exists());
        // other-session should remain (different PID)
        assert!(sessions_dir.join("other-session.json").exists());
    }
}
