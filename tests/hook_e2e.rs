//! End-to-end integration tests for the cctop-hook binary.
//!
//! These tests verify that the hook binary correctly processes stdin JSON
//! and writes/updates/removes session files.
//!
//! Each test gets its own isolated sessions directory via `CCTOP_SESSIONS_DIR`
//! env var, so tests run safely in parallel without interfering with each
//! other or real user data.

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use serde::Deserialize;
use tempfile::TempDir;

/// Session struct for deserializing JSON (simplified version for tests)
#[derive(Debug, Deserialize)]
struct TestSession {
    session_id: String,
    project_path: String,
    project_name: String,
    status: String,
    last_prompt: Option<String>,
    started_at: String,
    last_activity: String,
}

/// Isolated test environment. Each test gets its own temp sessions directory.
/// The directory is automatically cleaned up when TestEnv is dropped.
struct TestEnv {
    _temp_dir: TempDir,
    sessions_dir: PathBuf,
}

impl TestEnv {
    fn new() -> Self {
        let temp_dir = TempDir::new().expect("Failed to create temp directory");
        let sessions_dir = temp_dir.path().join("sessions");
        fs::create_dir_all(&sessions_dir).expect("Failed to create sessions dir");
        Self {
            _temp_dir: temp_dir,
            sessions_dir,
        }
    }

    fn run_hook(&self, event: &str, json_input: &str) -> std::process::Output {
        let binary = hook_binary();
        assert!(
            binary.exists(),
            "Hook binary not found at {:?}. Run `cargo build` first.",
            binary
        );

        let mut child = Command::new(&binary)
            .arg(event)
            .env("CCTOP_SESSIONS_DIR", &self.sessions_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("Failed to spawn hook binary");

        if let Some(mut stdin) = child.stdin.take() {
            stdin
                .write_all(json_input.as_bytes())
                .expect("Failed to write to stdin");
        }

        child.wait_with_output().expect("Failed to wait for hook")
    }

    fn load_session(&self, session_id: &str) -> TestSession {
        let path = self.session_path(session_id);
        let content = fs::read_to_string(&path).expect("Failed to read session file");
        serde_json::from_str(&content).expect("Failed to parse session JSON")
    }

    fn session_path(&self, session_id: &str) -> PathBuf {
        self.sessions_dir.join(format!("{}.json", session_id))
    }
}

/// Returns the path to the cctop-hook binary.
fn hook_binary() -> PathBuf {
    if let Some(path) = option_env!("CARGO_BIN_EXE_cctop-hook") {
        return PathBuf::from(path);
    }

    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.push("target");
    path.push("debug");
    path.push("cctop-hook");
    path
}

#[test]
fn test_hook_binary_session_start() {
    let env = TestEnv::new();
    let session_id = "test-session-start";

    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"SessionStart"}}"#,
        session_id
    );

    let output = env.run_hook("SessionStart", &json);
    assert!(output.status.success());

    assert!(
        env.session_path(session_id).exists(),
        "Session file should be created"
    );

    let session = env.load_session(session_id);
    assert_eq!(session.session_id, session_id);
    assert_eq!(session.status, "idle");
}

#[test]
fn test_hook_binary_user_prompt_submit() {
    let env = TestEnv::new();
    let session_id = "test-prompt-submit";

    // First create the session
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"SessionStart"}}"#,
        session_id
    );
    env.run_hook("SessionStart", &json);

    // Now submit a prompt
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"Fix the bug"}}"#,
        session_id
    );
    let output = env.run_hook("UserPromptSubmit", &json);
    assert!(output.status.success());

    let session = env.load_session(session_id);
    assert_eq!(session.status, "working");
    assert_eq!(session.last_prompt, Some("Fix the bug".to_string()));
}

#[test]
fn test_hook_binary_status_transitions() {
    let env = TestEnv::new();
    let session_id = "test-status-transitions";

    // SessionStart -> idle
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"SessionStart"}}"#,
        session_id
    );
    env.run_hook("SessionStart", &json);

    let session = env.load_session(session_id);
    assert_eq!(session.status, "idle", "SessionStart should set idle");

    // UserPromptSubmit -> working
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"test"}}"#,
        session_id
    );
    env.run_hook("UserPromptSubmit", &json);
    let session = env.load_session(session_id);
    assert_eq!(
        session.status, "working",
        "UserPromptSubmit should set working"
    );

    // PreToolUse -> working
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"PreToolUse","tool_name":"Bash"}}"#,
        session_id
    );
    env.run_hook("PreToolUse", &json);
    let session = env.load_session(session_id);
    assert_eq!(session.status, "working", "PreToolUse should keep working");

    // PostToolUse -> working
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"PostToolUse","tool_name":"Bash"}}"#,
        session_id
    );
    env.run_hook("PostToolUse", &json);
    let session = env.load_session(session_id);
    assert_eq!(session.status, "working", "PostToolUse should keep working");

    // Stop -> idle
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"Stop"}}"#,
        session_id
    );
    env.run_hook("Stop", &json);
    let session = env.load_session(session_id);
    assert_eq!(session.status, "idle", "Stop should set idle");

    // Notification (idle_prompt) -> waiting_input
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"Notification","notification_type":"idle_prompt"}}"#,
        session_id
    );
    env.run_hook("Notification", &json);
    let session = env.load_session(session_id);
    assert_eq!(
        session.status, "waiting_input",
        "Notification with idle_prompt should set waiting_input"
    );
}

#[test]
fn test_hook_binary_session_end() {
    let env = TestEnv::new();
    let session_id = "test-session-end";

    // Create session
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"SessionStart"}}"#,
        session_id
    );
    env.run_hook("SessionStart", &json);

    assert!(
        env.session_path(session_id).exists(),
        "Session file should exist"
    );

    // SessionEnd hook is now a no-op (file is NOT removed)
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"SessionEnd"}}"#,
        session_id
    );
    let output = env.run_hook("SessionEnd", &json);
    assert!(output.status.success());

    assert!(
        env.session_path(session_id).exists(),
        "Session file should still exist (cleaned up by liveness check, not SessionEnd)"
    );
}

#[test]
fn test_hook_binary_session_end_nonexistent() {
    let env = TestEnv::new();
    let session_id = "test-nonexistent-session";

    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"SessionEnd"}}"#,
        session_id
    );
    let output = env.run_hook("SessionEnd", &json);
    assert!(
        output.status.success(),
        "SessionEnd should succeed even if session doesn't exist"
    );
}

#[test]
fn test_hook_binary_invalid_json() {
    let env = TestEnv::new();

    // Hook should not block Claude Code on invalid JSON - exits 0
    let output = env.run_hook("SessionStart", "not valid json");
    assert!(
        output.status.success(),
        "Hook should exit 0 on invalid JSON to not block CC"
    );
}

#[test]
fn test_hook_binary_missing_event_arg() {
    let binary = hook_binary();

    // No arguments — doesn't need TestEnv since it never writes files
    let output = Command::new(&binary)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("Failed to run hook");

    assert!(
        output.status.success(),
        "Hook should exit 0 even without event arg"
    );
}

#[test]
fn test_hook_binary_project_name_extraction() {
    let env = TestEnv::new();
    let session_id = "test-project-name";

    let json = format!(
        r#"{{"session_id":"{}","cwd":"/Users/st0012/projects/my-awesome-project","hook_event_name":"SessionStart"}}"#,
        session_id
    );
    env.run_hook("SessionStart", &json);

    let session = env.load_session(session_id);
    assert_eq!(session.project_name, "my-awesome-project");
    assert_eq!(
        session.project_path,
        "/Users/st0012/projects/my-awesome-project"
    );
}

#[test]
fn test_hook_binary_preserves_started_at() {
    let env = TestEnv::new();
    let session_id = "test-started-at";

    // Create session
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"SessionStart"}}"#,
        session_id
    );
    env.run_hook("SessionStart", &json);

    let session1 = env.load_session(session_id);
    let original_started_at = session1.started_at.clone();

    // Update session
    std::thread::sleep(std::time::Duration::from_millis(100));
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"test"}}"#,
        session_id
    );
    env.run_hook("UserPromptSubmit", &json);

    let session2 = env.load_session(session_id);

    assert_eq!(
        session2.started_at, original_started_at,
        "started_at should be preserved across updates"
    );

    assert_ne!(
        session2.last_activity, original_started_at,
        "last_activity should be updated"
    );
}
