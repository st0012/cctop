//! End-to-end integration tests for the cctop-hook binary.
//!
//! These tests verify that the hook binary correctly processes stdin JSON
//! and writes/updates/removes session files.
//!
//! Note: These tests use the real ~/.cctop/sessions directory to test
//! actual hook behavior. Test session IDs are prefixed with "e2e-test-"
//! and cleaned up after each test.

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use serde::Deserialize;

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

/// Returns the path to the cctop-hook binary.
/// Uses CARGO_BIN_EXE for correct path detection in test profile.
fn hook_binary() -> PathBuf {
    // Try the cargo-provided path first (works in `cargo test`)
    if let Some(path) = option_env!("CARGO_BIN_EXE_cctop-hook") {
        return PathBuf::from(path);
    }

    // Fallback: construct path manually
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.push("target");
    path.push("debug");
    path.push("cctop-hook");
    path
}

/// Returns the sessions directory path.
fn sessions_dir() -> PathBuf {
    dirs::home_dir()
        .expect("Could not determine home directory")
        .join(".cctop")
        .join("sessions")
}

/// Runs the hook binary with the given event name and JSON input.
fn run_hook(event: &str, json_input: &str) -> std::process::Output {
    let binary = hook_binary();

    assert!(
        binary.exists(),
        "Hook binary not found at {:?}. Run `cargo build` first.",
        binary
    );

    let mut child = Command::new(&binary)
        .arg(event)
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

/// Clean up a test session file.
fn cleanup_session(session_id: &str) {
    let path = sessions_dir().join(format!("{}.json", session_id));
    let _ = fs::remove_file(path);
}

/// Load a test session from file.
fn load_session(session_id: &str) -> TestSession {
    let path = sessions_dir().join(format!("{}.json", session_id));
    let content = fs::read_to_string(&path).expect("Failed to read session file");
    serde_json::from_str(&content).expect("Failed to parse session JSON")
}

#[test]
fn test_hook_binary_session_start() {
    let session_id = "e2e-test-session-start";
    cleanup_session(session_id);

    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"SessionStart"}}"#,
        session_id
    );

    let output = run_hook("SessionStart", &json);
    assert!(output.status.success());

    // Verify session file was created
    let session_path = sessions_dir().join(format!("{}.json", session_id));
    assert!(session_path.exists(), "Session file should be created");

    // Verify content
    let session = load_session(session_id);
    assert_eq!(session.session_id, session_id);
    assert_eq!(session.status, "idle");

    cleanup_session(session_id);
}

#[test]
fn test_hook_binary_user_prompt_submit() {
    let session_id = "e2e-test-prompt-submit";
    cleanup_session(session_id);

    // First create the session
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"SessionStart"}}"#,
        session_id
    );
    run_hook("SessionStart", &json);

    // Now submit a prompt
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"Fix the bug"}}"#,
        session_id
    );
    let output = run_hook("UserPromptSubmit", &json);
    assert!(output.status.success());

    // Verify status and prompt
    let session = load_session(session_id);
    assert_eq!(session.status, "working");
    assert_eq!(session.last_prompt, Some("Fix the bug".to_string()));

    cleanup_session(session_id);
}

#[test]
fn test_hook_binary_status_transitions() {
    let session_id = "e2e-test-status-transitions";
    cleanup_session(session_id);

    // SessionStart -> idle
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"SessionStart"}}"#,
        session_id
    );
    run_hook("SessionStart", &json);

    let session = load_session(session_id);
    assert_eq!(session.status, "idle", "SessionStart should set idle");

    // UserPromptSubmit -> working
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"test"}}"#,
        session_id
    );
    run_hook("UserPromptSubmit", &json);
    let session = load_session(session_id);
    assert_eq!(
        session.status, "working",
        "UserPromptSubmit should set working"
    );

    // PreToolUse -> working
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"PreToolUse","tool_name":"Bash"}}"#,
        session_id
    );
    run_hook("PreToolUse", &json);
    let session = load_session(session_id);
    assert_eq!(session.status, "working", "PreToolUse should keep working");

    // PostToolUse -> working
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"PostToolUse","tool_name":"Bash"}}"#,
        session_id
    );
    run_hook("PostToolUse", &json);
    let session = load_session(session_id);
    assert_eq!(session.status, "working", "PostToolUse should keep working");

    // Stop -> idle
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"Stop"}}"#,
        session_id
    );
    run_hook("Stop", &json);
    let session = load_session(session_id);
    assert_eq!(session.status, "idle", "Stop should set idle");

    // Notification (idle_prompt) -> waiting_input
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"Notification","notification_type":"idle_prompt"}}"#,
        session_id
    );
    run_hook("Notification", &json);
    let session = load_session(session_id);
    assert_eq!(
        session.status, "waiting_input",
        "Notification with idle_prompt should set waiting_input"
    );

    cleanup_session(session_id);
}

#[test]
fn test_hook_binary_session_end() {
    // SessionEnd is no longer used - PID-based liveness detection replaces it.
    // This test verifies the hook still succeeds (is a no-op) for backwards compatibility.
    let session_id = "e2e-test-session-end";
    cleanup_session(session_id);

    // Create session
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"SessionStart"}}"#,
        session_id
    );
    run_hook("SessionStart", &json);

    let session_path = sessions_dir().join(format!("{}.json", session_id));
    assert!(session_path.exists(), "Session file should exist");

    // SessionEnd hook is now a no-op (file is NOT removed)
    // Dead sessions are detected via PID checking instead
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"SessionEnd"}}"#,
        session_id
    );
    let output = run_hook("SessionEnd", &json);
    assert!(output.status.success());

    // Session file still exists (will be cleaned up by PID-based liveness check)
    assert!(
        session_path.exists(),
        "Session file should still exist (cleaned up by liveness check, not SessionEnd)"
    );

    cleanup_session(session_id);
}

#[test]
fn test_hook_binary_session_end_nonexistent() {
    let session_id = "e2e-test-nonexistent-session";
    cleanup_session(session_id);

    // SessionEnd on non-existent session should still succeed (it's a no-op)
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"SessionEnd"}}"#,
        session_id
    );
    let output = run_hook("SessionEnd", &json);
    assert!(
        output.status.success(),
        "SessionEnd should succeed even if session doesn't exist"
    );
}

#[test]
fn test_hook_binary_invalid_json() {
    // Hook should not block Claude Code on invalid JSON - exits 0
    let output = run_hook("SessionStart", "not valid json");
    assert!(
        output.status.success(),
        "Hook should exit 0 on invalid JSON to not block CC"
    );
}

#[test]
fn test_hook_binary_missing_event_arg() {
    let binary = hook_binary();

    // No arguments
    let output = Command::new(&binary)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("Failed to run hook");

    // Should exit 0 to not block CC
    assert!(
        output.status.success(),
        "Hook should exit 0 even without event arg"
    );
}

#[test]
fn test_hook_binary_project_name_extraction() {
    let session_id = "e2e-test-project-name";
    cleanup_session(session_id);

    let json = format!(
        r#"{{"session_id":"{}","cwd":"/Users/st0012/projects/my-awesome-project","hook_event_name":"SessionStart"}}"#,
        session_id
    );
    run_hook("SessionStart", &json);

    let session = load_session(session_id);
    assert_eq!(session.project_name, "my-awesome-project");
    assert_eq!(
        session.project_path,
        "/Users/st0012/projects/my-awesome-project"
    );

    cleanup_session(session_id);
}

#[test]
fn test_hook_binary_preserves_started_at() {
    let session_id = "e2e-test-started-at";
    cleanup_session(session_id);

    // Create session
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"SessionStart"}}"#,
        session_id
    );
    run_hook("SessionStart", &json);

    let session1 = load_session(session_id);
    let original_started_at = session1.started_at.clone();

    // Update session
    std::thread::sleep(std::time::Duration::from_millis(100));
    let json = format!(
        r#"{{"session_id":"{}","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"test"}}"#,
        session_id
    );
    run_hook("UserPromptSubmit", &json);

    let session2 = load_session(session_id);

    // started_at should be preserved
    assert_eq!(
        session2.started_at, original_started_at,
        "started_at should be preserved across updates"
    );

    // But last_activity should have changed
    assert_ne!(
        session2.last_activity, original_started_at,
        "last_activity should be updated"
    );

    cleanup_session(session_id);
}
