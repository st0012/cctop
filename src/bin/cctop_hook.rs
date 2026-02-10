//! cctop-hook: Claude Code hook handler binary.
//!
//! This binary is called by Claude Code hooks to track session state.
//! It reads hook event data from stdin and updates session files in ~/.cctop/sessions/.
//!
//! Usage: cctop-hook <HookName>
//!
//! Hook names: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, Notification, PermissionRequest, PreCompact, SessionEnd

use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write as IoWrite};
use std::path::Path;
use std::process;

use chrono::Utc;
use serde::Deserialize;
use serde_json::Value;

use cctop::config::Config;
use cctop::git::get_current_branch;
#[cfg(test)]
use cctop::session::Status;
use cctop::session::{
    is_pid_alive, sanitize_session_id, HookEvent, Session, TerminalInfo, Transition,
};

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
                    cleanup_session_log(&session.session_id);
                }
            }
        }
    }
}

/// Maximum age for sessions without a PID before they are cleaned up.
const NO_PID_MAX_AGE: chrono::Duration = chrono::Duration::hours(24);

/// Clean up dead session files for the same project path.
///
/// Only removes sessions whose PID is dead (process no longer running).
/// Sessions with no PID are cleaned up only if their last activity is older
/// than 24 hours. Sessions with a live PID are always preserved.
fn cleanup_sessions_for_project(sessions_dir: &Path, project_path: &str, current_session_id: &str) {
    use std::fs;

    let Ok(entries) = fs::read_dir(sessions_dir) else {
        return;
    };

    let now = Utc::now();

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().map(|e| e == "json").unwrap_or(false) {
            if let Ok(session) = Session::from_file(&path) {
                if session.project_path != project_path || session.session_id == current_session_id
                {
                    continue;
                }

                let should_remove = match session.pid {
                    Some(pid) => !is_pid_alive(pid),
                    None => {
                        // No PID: only clean up if older than threshold
                        now.signed_duration_since(session.last_activity) > NO_PID_MAX_AGE
                    }
                };

                if should_remove {
                    let _ = fs::remove_file(&path);
                    cleanup_session_log(&session.session_id);
                }
            }
        }
    }
}

// --- Per-session logging to ~/.cctop/logs/{session_id}.log ---

fn logs_dir() -> Option<std::path::PathBuf> {
    dirs::home_dir().map(|h| h.join(".cctop").join("logs"))
}

fn session_log_path(session_id: &str) -> Option<std::path::PathBuf> {
    logs_dir().map(|d| d.join(format!("{}.log", session_id)))
}

fn session_label(cwd: &str, session_id: &str) -> String {
    let project = Path::new(cwd)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("unknown");
    let abbrev = &session_id[..session_id.len().min(8)];
    format!("{}:{}", project, abbrev)
}

fn append_hook_log(
    session_id: &str,
    event: &str,
    label: &str,
    old_status: &str,
    new_status: &str,
    note: &str,
) {
    let Some(log_path) = session_log_path(session_id) else {
        return;
    };
    let _ = fs::create_dir_all(log_path.parent().unwrap());
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&log_path) {
        let extra = if note.is_empty() {
            String::new()
        } else {
            format!(" ({})", note)
        };
        let _ = writeln!(
            f,
            "{} HOOK {} {} {} -> {}{}",
            Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
            event,
            label,
            old_status,
            new_status,
            extra,
        );
    }
}

/// Log errors that occur before we know the session ID (parse failures, missing args).
fn log_error(msg: &str) {
    let Some(dir) = logs_dir() else { return };
    let _ = fs::create_dir_all(&dir);
    let log_path = dir.join("_errors.log");
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&log_path) {
        let _ = writeln!(
            f,
            "{} ERROR {}",
            Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
            msg
        );
    }
}

/// Remove log file for a session (called alongside session file cleanup).
fn cleanup_session_log(session_id: &str) {
    if let Some(log_path) = session_log_path(session_id) {
        let _ = fs::remove_file(log_path);
    }
}

/// Handles a hook event by updating or creating the session file.
fn handle_hook(hook_name: &str, input: HookInput) -> Result<(), Box<dyn std::error::Error>> {
    // Parse typed event
    let event = HookEvent::parse(hook_name, input.notification_type.as_deref());

    // SessionEnd is a no-op (PID-based liveness detection handles cleanup)
    if event == HookEvent::SessionEnd {
        return Ok(());
    }

    let sessions_dir = Config::sessions_dir();
    let safe_id = sanitize_session_id(&input.session_id);
    let label = session_label(&input.cwd, &safe_id);
    let session_path = sessions_dir.join(format!("{}.json", safe_id));

    // Get branch name
    let cwd_path = Path::new(&input.cwd);
    let branch = get_current_branch(cwd_path);

    // Capture terminal info
    let terminal = capture_terminal_info();

    // Load existing session or create new one
    let mut session = if session_path.exists() {
        match Session::from_file(&session_path) {
            Ok(s) => s,
            Err(_) => {
                // If file is corrupted, create new session
                Session::new(
                    safe_id.clone(),
                    input.cwd.clone(),
                    branch.clone(),
                    terminal.clone(),
                )
            }
        }
    } else {
        Session::new(
            safe_id.clone(),
            input.cwd.clone(),
            branch.clone(),
            terminal.clone(),
        )
    };

    // Track the old status for logging
    let old_status = session.status.as_str().to_string();

    // Use the centralized transition table for status changes.
    let status_preserved = Transition::for_event(&session.status, &event).is_none();
    if let Some(new_status) = Transition::for_event(&session.status, &event) {
        session.status = new_status;
    }

    session.last_activity = Utc::now();
    session.branch = branch;
    session.terminal = terminal;

    // Apply side effects per hook event
    match event {
        HookEvent::SessionStart => {
            // Clear transient fields on session start
            session.last_tool = None;
            session.last_tool_detail = None;
            session.notification_message = None;

            // Capture the parent PID (the Claude Code process)
            let pid = get_parent_pid();
            session.pid = pid;

            // Clean up old sessions for the same project or PID
            cleanup_sessions_for_project(&sessions_dir, &input.cwd, &safe_id);
            if let Some(current_pid) = pid {
                cleanup_sessions_with_pid(&sessions_dir, current_pid, &safe_id);
            }
        }

        HookEvent::UserPromptSubmit => {
            // Clear tool/notification state, set prompt
            session.last_tool = None;
            session.last_tool_detail = None;
            session.notification_message = None;

            if let Some(prompt) = input.prompt {
                session.last_prompt = Some(prompt);
            }
        }

        HookEvent::PreToolUse => {
            // Set last_tool and extract detail from tool_input
            if let Some(ref tool_name) = input.tool_name {
                session.last_tool = Some(tool_name.clone());
                session.last_tool_detail = input
                    .tool_input
                    .as_ref()
                    .and_then(|ti| extract_tool_detail(tool_name, ti));
            }
        }

        HookEvent::PermissionRequest => {
            // Build notification message from title or tool details
            let msg = input.title.or_else(|| {
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

        HookEvent::NotificationIdle
        | HookEvent::NotificationPermission
        | HookEvent::NotificationOther => {
            // Clear stale tool info when transitioning out of Working
            session.last_tool = None;
            session.last_tool_detail = None;
            // Store notification message if present
            if let Some(ref msg) = input.message {
                session.notification_message = Some(msg.clone());
            }
        }

        HookEvent::PreCompact => {
            // Status transition handled by Transition::for_event above
        }

        HookEvent::Stop => {
            // Clear all transient fields when the turn ends
            session.last_tool = None;
            session.last_tool_detail = None;
            session.notification_message = None;
        }

        HookEvent::PostToolUse | HookEvent::SessionEnd | HookEvent::Unknown => {}
    }

    // Log the status transition
    let note = if status_preserved { "preserved" } else { "" };
    append_hook_log(
        &safe_id,
        hook_name,
        &label,
        &old_status,
        session.status.as_str(),
        note,
    );

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

    // Handle --help flag
    if args.len() >= 2 && (args[1] == "--help" || args[1] == "-h") {
        println!("cctop-hook {}", env!("CARGO_PKG_VERSION"));
        println!("Claude Code hook handler for cctop session tracking.\n");
        println!("This binary is called by Claude Code hooks via the cctop plugin.");
        println!("It reads hook event JSON from stdin and updates session files");
        println!("in ~/.cctop/sessions/.\n");
        println!("USAGE:");
        println!("    cctop-hook <HOOK_NAME>\n");
        println!("HOOK NAMES:");
        println!("    SessionStart, UserPromptSubmit, PreToolUse, PostToolUse,");
        println!("    Stop, Notification, PermissionRequest, PreCompact, SessionEnd\n");
        println!("OPTIONS:");
        println!("    -h, --help       Print this help message");
        println!("    -V, --version    Print version");
        process::exit(0);
    }

    if args.len() < 2 {
        log_error("missing hook name argument");
        process::exit(0); // Exit 0 to not block Claude Code
    }
    let hook_name = &args[1];

    // Read JSON from stdin with timeout to prevent hanging if stdin never closes
    let stdin_buf = {
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut buf = String::new();
            let result = io::stdin().read_to_string(&mut buf);
            let _ = tx.send((buf, result));
        });
        match rx.recv_timeout(std::time::Duration::from_secs(5)) {
            Ok((buf, Ok(_))) => buf,
            Ok((_, Err(e))) => {
                log_error(&format!("{}: failed to read stdin: {}", hook_name, e));
                process::exit(0);
            }
            Err(_) => {
                log_error(&format!("{}: stdin read timed out after 5s", hook_name));
                process::exit(0);
            }
        }
    };

    // Parse JSON input
    let input: HookInput = match serde_json::from_str(&stdin_buf) {
        Ok(i) => i,
        Err(e) => {
            log_error(&format!("{}: failed to parse JSON: {}", hook_name, e));
            process::exit(0);
        }
    };

    // Handle the hook
    if let Err(e) = handle_hook(hook_name, input) {
        log_error(&format!("{}: {}", hook_name, e));
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

    #[test]
    fn test_cleanup_sessions_for_project() {
        use tempfile::tempdir;

        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path();

        // Old session for same project with dead PID (should be removed)
        let mut old_session = Session::new(
            "old-session".to_string(),
            "/nonexistent/test/project".to_string(),
            "main".to_string(),
            TerminalInfo::default(),
        );
        old_session.pid = Some(999999); // dead PID
        old_session.write_to_dir(sessions_dir).unwrap();

        // Another old session with no PID and old timestamp (should be removed)
        let mut no_pid_session = Session::new(
            "no-pid-session".to_string(),
            "/nonexistent/test/project".to_string(),
            "main".to_string(),
            TerminalInfo::default(),
        );
        no_pid_session.last_activity = Utc::now() - chrono::Duration::hours(25);
        no_pid_session.write_to_dir(sessions_dir).unwrap();

        // Session for a different project (should not be removed)
        let other_project = Session::new(
            "other-project".to_string(),
            "/nonexistent/test/other".to_string(),
            "main".to_string(),
            TerminalInfo::default(),
        );
        other_project.write_to_dir(sessions_dir).unwrap();

        // New session for same project
        let new_session = Session::new(
            "new-session".to_string(),
            "/nonexistent/test/project".to_string(),
            "main".to_string(),
            TerminalInfo::default(),
        );
        new_session.write_to_dir(sessions_dir).unwrap();

        assert_eq!(
            std::fs::read_dir(sessions_dir).unwrap().count(),
            4,
            "Should have 4 session files"
        );

        cleanup_sessions_for_project(sessions_dir, "/nonexistent/test/project", "new-session");

        // Dead PID session should be removed
        assert!(!sessions_dir.join("old-session.json").exists());
        // Old no-PID session should be removed
        assert!(!sessions_dir.join("no-pid-session.json").exists());
        // New session should remain
        assert!(sessions_dir.join("new-session.json").exists());
        // Different project should remain
        assert!(sessions_dir.join("other-project.json").exists());
    }

    /// Helper: create a session file in the given directory with a specific status.
    fn write_session_with_status(
        sessions_dir: &std::path::Path,
        session_id: &str,
        status: Status,
        notification_message: Option<String>,
    ) {
        let mut session = Session::new(
            session_id.to_string(),
            "/nonexistent/test/project".to_string(),
            "main".to_string(),
            TerminalInfo::default(),
        );
        session.status = status;
        session.notification_message = notification_message;
        session.write_to_dir(sessions_dir).unwrap();
    }

    /// Mutex to serialize tests that modify the CCTOP_SESSIONS_DIR env var,
    /// since env vars are process-global and tests run in parallel.
    static ENV_MUTEX: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// Helper: run handle_hook with a given event against an existing session in a temp dir.
    /// Must be called while holding ENV_MUTEX.
    fn run_hook_in_dir(
        sessions_dir: &std::path::Path,
        session_id: &str,
        event: &str,
        notification_type: Option<&str>,
    ) {
        let input = HookInput {
            session_id: session_id.to_string(),
            cwd: "/nonexistent/test/project".to_string(),
            transcript_path: None,
            permission_mode: None,
            hook_event_name: event.to_string(),
            prompt: None,
            tool_name: None,
            tool_input: None,
            notification_type: notification_type.map(|s| s.to_string()),
            message: None,
            title: None,
            trigger: None,
        };

        // Override sessions dir via env var so handle_hook writes to our temp dir
        std::env::set_var("CCTOP_SESSIONS_DIR", sessions_dir);
        handle_hook(event, input).unwrap();
        std::env::remove_var("CCTOP_SESSIONS_DIR");
    }

    #[test]
    fn test_stop_clears_waiting_input() {
        use tempfile::tempdir;
        let _lock = ENV_MUTEX.lock().unwrap();

        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path();

        // Set up a session in waiting_input state
        write_session_with_status(
            sessions_dir,
            "preserve-test",
            Status::WaitingInput,
            Some("Your turn".to_string()),
        );

        // Fire Stop — should transition to idle
        run_hook_in_dir(sessions_dir, "preserve-test", "Stop", None);

        let session = Session::from_file(&sessions_dir.join("preserve-test.json")).unwrap();
        assert_eq!(
            session.status,
            Status::Idle,
            "Stop should transition waiting_input to idle"
        );
    }

    #[test]
    fn test_stop_clears_waiting_permission() {
        use tempfile::tempdir;
        let _lock = ENV_MUTEX.lock().unwrap();

        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path();

        // Set up a session in waiting_permission state
        write_session_with_status(
            sessions_dir,
            "perm-test",
            Status::WaitingPermission,
            Some("Allow Bash?".to_string()),
        );

        // Fire Stop — should transition to idle
        run_hook_in_dir(sessions_dir, "perm-test", "Stop", None);

        let session = Session::from_file(&sessions_dir.join("perm-test.json")).unwrap();
        assert_eq!(
            session.status,
            Status::Idle,
            "Stop should transition waiting_permission to idle"
        );
    }

    #[test]
    fn test_stop_clears_working_to_idle() {
        use tempfile::tempdir;
        let _lock = ENV_MUTEX.lock().unwrap();

        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path();

        // Set up a session in working state
        write_session_with_status(sessions_dir, "working-test", Status::Working, None);

        // Fire Stop — should transition working -> idle as before
        run_hook_in_dir(sessions_dir, "working-test", "Stop", None);

        let session = Session::from_file(&sessions_dir.join("working-test.json")).unwrap();
        assert_eq!(
            session.status,
            Status::Idle,
            "Stop should transition working to idle"
        );
    }

    #[test]
    fn test_notification_then_stop_sequence() {
        use tempfile::tempdir;
        let _lock = ENV_MUTEX.lock().unwrap();

        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path();

        // Start with a working session
        write_session_with_status(sessions_dir, "sequence-test", Status::Working, None);

        // Notification(idle_prompt) fires first -> should set waiting_input
        run_hook_in_dir(
            sessions_dir,
            "sequence-test",
            "Notification",
            Some("idle_prompt"),
        );

        let session = Session::from_file(&sessions_dir.join("sequence-test.json")).unwrap();
        assert_eq!(session.status, Status::WaitingInput);

        // Stop fires after -> should transition to idle
        run_hook_in_dir(sessions_dir, "sequence-test", "Stop", None);

        let session = Session::from_file(&sessions_dir.join("sequence-test.json")).unwrap();
        assert_eq!(
            session.status,
            Status::Idle,
            "Full sequence: Notification then Stop should end in idle"
        );
    }

    #[test]
    fn test_user_prompt_after_preserved_waiting_input() {
        use tempfile::tempdir;
        let _lock = ENV_MUTEX.lock().unwrap();

        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path();

        // Session in waiting_input (after Notification + Stop preserved it)
        write_session_with_status(
            sessions_dir,
            "resume-test",
            Status::WaitingInput,
            Some("Your turn".to_string()),
        );

        // User types a new prompt -> should transition to working and clear notification
        run_hook_in_dir(sessions_dir, "resume-test", "UserPromptSubmit", None);

        let session = Session::from_file(&sessions_dir.join("resume-test.json")).unwrap();
        assert_eq!(
            session.status,
            Status::Working,
            "UserPromptSubmit should transition waiting_input to working"
        );
        assert_eq!(
            session.notification_message, None,
            "UserPromptSubmit should clear notification_message"
        );
    }

    #[test]
    fn test_precompact_sets_compacting() {
        use tempfile::tempdir;
        let _lock = ENV_MUTEX.lock().unwrap();

        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path();

        // Start with a working session
        write_session_with_status(sessions_dir, "compact-test", Status::Working, None);

        // Fire PreCompact -> should set compacting
        run_hook_in_dir(sessions_dir, "compact-test", "PreCompact", None);

        let session = Session::from_file(&sessions_dir.join("compact-test.json")).unwrap();
        assert_eq!(
            session.status,
            Status::Compacting,
            "PreCompact should transition to compacting"
        );
    }

    #[test]
    fn test_cleanup_preserves_live_sessions_same_project() {
        use tempfile::tempdir;

        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path();

        let current_pid = std::process::id();

        // Two sessions for the same project, both with our (live) PID
        let mut session1 = Session::new(
            "live-session-1".to_string(),
            "/nonexistent/test/project".to_string(),
            "main".to_string(),
            TerminalInfo::default(),
        );
        session1.pid = Some(current_pid);
        session1.write_to_dir(sessions_dir).unwrap();

        let mut session2 = Session::new(
            "live-session-2".to_string(),
            "/nonexistent/test/project".to_string(),
            "main".to_string(),
            TerminalInfo::default(),
        );
        session2.pid = Some(current_pid);
        session2.write_to_dir(sessions_dir).unwrap();

        // Cleanup from the perspective of session2
        cleanup_sessions_for_project(sessions_dir, "/nonexistent/test/project", "live-session-2");

        // Both should still exist because the PID is alive
        assert!(
            sessions_dir.join("live-session-1.json").exists(),
            "Live session should NOT be deleted"
        );
        assert!(
            sessions_dir.join("live-session-2.json").exists(),
            "Current session should NOT be deleted"
        );
    }

    #[test]
    fn test_cleanup_removes_dead_sessions_same_project() {
        use tempfile::tempdir;

        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path();

        let current_pid = std::process::id();

        // Dead session for same project (PID 999999 almost certainly doesn't exist)
        let mut dead_session = Session::new(
            "dead-session".to_string(),
            "/nonexistent/test/project".to_string(),
            "main".to_string(),
            TerminalInfo::default(),
        );
        dead_session.pid = Some(999999);
        dead_session.write_to_dir(sessions_dir).unwrap();

        // Current (live) session
        let mut live_session = Session::new(
            "current-session".to_string(),
            "/nonexistent/test/project".to_string(),
            "main".to_string(),
            TerminalInfo::default(),
        );
        live_session.pid = Some(current_pid);
        live_session.write_to_dir(sessions_dir).unwrap();

        cleanup_sessions_for_project(sessions_dir, "/nonexistent/test/project", "current-session");

        // Dead session should be removed
        assert!(
            !sessions_dir.join("dead-session.json").exists(),
            "Dead session should be removed"
        );
        // Current session should remain
        assert!(
            sessions_dir.join("current-session.json").exists(),
            "Current session should be preserved"
        );
    }

    #[test]
    fn test_cleanup_removes_old_no_pid_sessions() {
        use tempfile::tempdir;

        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path();

        // Session with no PID and old timestamp (>24h ago)
        let mut old_no_pid = Session::new(
            "old-no-pid".to_string(),
            "/nonexistent/test/project".to_string(),
            "main".to_string(),
            TerminalInfo::default(),
        );
        old_no_pid.pid = None;
        old_no_pid.last_activity = Utc::now() - chrono::Duration::hours(25);
        old_no_pid.write_to_dir(sessions_dir).unwrap();

        // Current session
        let new_session = Session::new(
            "new-session".to_string(),
            "/nonexistent/test/project".to_string(),
            "main".to_string(),
            TerminalInfo::default(),
        );
        new_session.write_to_dir(sessions_dir).unwrap();

        cleanup_sessions_for_project(sessions_dir, "/nonexistent/test/project", "new-session");

        // Old no-PID session should be removed
        assert!(
            !sessions_dir.join("old-no-pid.json").exists(),
            "Old no-PID session (>24h) should be removed"
        );
        // New session should remain
        assert!(
            sessions_dir.join("new-session.json").exists(),
            "Current session should be preserved"
        );
    }

    #[test]
    fn test_cleanup_preserves_recent_no_pid_sessions() {
        use tempfile::tempdir;

        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path();

        // Session with no PID but recent timestamp (just created)
        let mut recent_no_pid = Session::new(
            "recent-no-pid".to_string(),
            "/nonexistent/test/project".to_string(),
            "main".to_string(),
            TerminalInfo::default(),
        );
        recent_no_pid.pid = None;
        // last_activity defaults to now, which is recent
        recent_no_pid.write_to_dir(sessions_dir).unwrap();

        // Current session
        let new_session = Session::new(
            "new-session".to_string(),
            "/nonexistent/test/project".to_string(),
            "main".to_string(),
            TerminalInfo::default(),
        );
        new_session.write_to_dir(sessions_dir).unwrap();

        cleanup_sessions_for_project(sessions_dir, "/nonexistent/test/project", "new-session");

        // Recent no-PID session should be preserved
        assert!(
            sessions_dir.join("recent-no-pid.json").exists(),
            "Recent no-PID session should be preserved (might be just-started)"
        );
        // New session should remain
        assert!(
            sessions_dir.join("new-session.json").exists(),
            "Current session should be preserved"
        );
    }
}
