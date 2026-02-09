//! Integration tests for session file I/O operations.
//!
//! These tests verify atomic writes, concurrent access, and file cleanup.

use cctop::session::{cleanup_stale_sessions, Session, Status, TerminalInfo};
use chrono::{Duration, Utc};
use std::fs;
use std::thread;
use tempfile::tempdir;

fn create_test_session(session_id: &str, project: &str) -> Session {
    Session {
        session_id: session_id.to_string(),
        project_path: format!("/nonexistent/test/projects/{}", project),
        project_name: project.to_string(),
        branch: "main".to_string(),
        status: Status::Idle,
        last_prompt: Some("Test prompt".to_string()),
        last_activity: Utc::now(),
        started_at: Utc::now(),
        terminal: TerminalInfo {
            program: "iTerm.app".to_string(),
            session_id: Some("w0t0p0:12345".to_string()),
            tty: Some("/dev/ttys003".to_string()),
        },
        pid: None,
        last_tool: None,
        last_tool_detail: None,
        notification_message: None,
    }
}

#[test]
fn test_write_and_read_session_file() {
    let temp_dir = tempdir().unwrap();
    let sessions_dir = temp_dir.path().join("sessions");

    let session = create_test_session("test123", "myproject");
    session.write_to_dir(&sessions_dir).unwrap();

    let sessions = Session::load_all(&sessions_dir).unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].session_id, "test123");
    assert_eq!(sessions[0].project_name, "myproject");
}

#[test]
fn test_atomic_write_creates_no_partial_files() {
    let temp_dir = tempdir().unwrap();
    let sessions_dir = temp_dir.path().join("sessions");

    let session = create_test_session("atomic-test", "proj");
    session.write_to_dir(&sessions_dir).unwrap();

    // Verify no temp file remains
    let temp_path = sessions_dir.join("atomic-test.json.tmp");
    assert!(
        !temp_path.exists(),
        "Temp file should not remain after write"
    );

    // Verify final file exists and is valid
    let final_path = sessions_dir.join("atomic-test.json");
    assert!(final_path.exists(), "Final file should exist");

    // File should be valid JSON
    let content = fs::read_to_string(&final_path).unwrap();
    let parsed: Session = serde_json::from_str(&content).unwrap();
    assert_eq!(parsed.session_id, "atomic-test");
}

#[test]
fn test_stale_session_cleanup() {
    let temp_dir = tempdir().unwrap();
    let sessions_dir = temp_dir.path().join("sessions");

    // Create a fresh session
    let mut fresh_session = create_test_session("fresh", "proj1");
    fresh_session.last_activity = Utc::now();
    fresh_session.write_to_dir(&sessions_dir).unwrap();

    // Create an old session (25 hours ago)
    let mut old_session = create_test_session("old", "proj2");
    old_session.last_activity = Utc::now() - Duration::hours(25);
    old_session.write_to_dir(&sessions_dir).unwrap();

    // Verify both exist
    assert_eq!(Session::load_all(&sessions_dir).unwrap().len(), 2);

    // Cleanup with 24 hour threshold
    cleanup_stale_sessions(&sessions_dir, Duration::hours(24)).unwrap();

    // Only fresh session should remain
    let remaining = Session::load_all(&sessions_dir).unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].session_id, "fresh");
}

#[test]
fn test_concurrent_writes_different_sessions() {
    let temp_dir = tempdir().unwrap();
    let sessions_dir = temp_dir.path().join("sessions");
    fs::create_dir_all(&sessions_dir).unwrap();

    let sessions_dir_clone = sessions_dir.clone();

    // Spawn multiple threads writing different sessions
    let handles: Vec<_> = (0..10)
        .map(|i| {
            let dir = sessions_dir_clone.clone();
            thread::spawn(move || {
                let session =
                    create_test_session(&format!("concurrent-{}", i), &format!("proj{}", i));
                session.write_to_dir(&dir).unwrap();
            })
        })
        .collect();

    // Wait for all threads
    for handle in handles {
        handle.join().unwrap();
    }

    // All sessions should exist
    let sessions = Session::load_all(&sessions_dir).unwrap();
    assert_eq!(sessions.len(), 10);
}

#[test]
fn test_overwrite_existing_session() {
    let temp_dir = tempdir().unwrap();
    let sessions_dir = temp_dir.path().join("sessions");

    // Create initial session
    let mut session = create_test_session("overwrite-test", "proj");
    session.status = Status::Idle;
    session.last_prompt = Some("First prompt".to_string());
    session.write_to_dir(&sessions_dir).unwrap();

    // Overwrite with updated session
    session.status = Status::Working;
    session.last_prompt = Some("Second prompt".to_string());
    session.write_to_dir(&sessions_dir).unwrap();

    // Read and verify
    let sessions = Session::load_all(&sessions_dir).unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].status, Status::Working);
    assert_eq!(sessions[0].last_prompt, Some("Second prompt".to_string()));
}

#[test]
fn test_load_skips_invalid_json_files() {
    let temp_dir = tempdir().unwrap();
    let sessions_dir = temp_dir.path().join("sessions");
    fs::create_dir_all(&sessions_dir).unwrap();

    // Write a valid session
    let session = create_test_session("valid", "proj");
    session.write_to_dir(&sessions_dir).unwrap();

    // Write an invalid JSON file
    fs::write(sessions_dir.join("invalid.json"), "not valid json {").unwrap();

    // Write a non-JSON file (should be ignored)
    fs::write(sessions_dir.join("readme.txt"), "ignore me").unwrap();

    // Load should only return the valid session
    let sessions = Session::load_all(&sessions_dir).unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].session_id, "valid");
}

#[test]
fn test_load_skips_temp_files() {
    let temp_dir = tempdir().unwrap();
    let sessions_dir = temp_dir.path().join("sessions");
    fs::create_dir_all(&sessions_dir).unwrap();

    // Write a valid session
    let session = create_test_session("valid", "proj");
    session.write_to_dir(&sessions_dir).unwrap();

    // Write a temp file (simulating interrupted write)
    fs::write(sessions_dir.join("temp.json.tmp"), "{}").unwrap();

    // Load should only return the valid session
    let sessions = Session::load_all(&sessions_dir).unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].session_id, "valid");
}

#[test]
fn test_session_removal() {
    let temp_dir = tempdir().unwrap();
    let sessions_dir = temp_dir.path().join("sessions");

    let session = create_test_session("to-remove", "proj");
    session.write_to_dir(&sessions_dir).unwrap();

    // Verify exists
    let path = sessions_dir.join("to-remove.json");
    assert!(path.exists());

    // Remove
    session.remove_from_dir(&sessions_dir).unwrap();
    assert!(!path.exists());
}

#[test]
fn test_remove_nonexistent_session_ok() {
    let temp_dir = tempdir().unwrap();
    let sessions_dir = temp_dir.path().join("sessions");
    fs::create_dir_all(&sessions_dir).unwrap();

    let session = create_test_session("nonexistent", "proj");

    // Should not error when removing non-existent session
    let result = session.remove_from_dir(&sessions_dir);
    assert!(result.is_ok());
}

#[test]
fn test_session_serialization_roundtrip_all_fields() {
    let original = Session {
        session_id: "roundtrip-all".to_string(),
        project_path: "/nonexistent/test/projects/testproj".to_string(),
        project_name: "testproj".to_string(),
        branch: "feature/test".to_string(),
        status: Status::NeedsAttention,
        last_prompt: Some("A very long prompt that tests serialization".to_string()),
        last_activity: Utc::now(),
        started_at: Utc::now() - Duration::hours(2),
        terminal: TerminalInfo {
            program: "kitty".to_string(),
            session_id: Some("12345".to_string()),
            tty: Some("/dev/ttys007".to_string()),
        },
        pid: Some(12345),
        last_tool: None,
        last_tool_detail: None,
        notification_message: None,
    };

    let json = serde_json::to_string_pretty(&original).unwrap();
    let parsed: Session = serde_json::from_str(&json).unwrap();

    assert_eq!(original.session_id, parsed.session_id);
    assert_eq!(original.project_path, parsed.project_path);
    assert_eq!(original.project_name, parsed.project_name);
    assert_eq!(original.branch, parsed.branch);
    assert_eq!(original.status, parsed.status);
    assert_eq!(original.last_prompt, parsed.last_prompt);
    assert_eq!(original.terminal.program, parsed.terminal.program);
    assert_eq!(original.terminal.session_id, parsed.terminal.session_id);
    assert_eq!(original.terminal.tty, parsed.terminal.tty);
}

#[test]
fn test_status_serialization() {
    // Test all status values serialize correctly
    let mut session = create_test_session("status-test", "proj");

    session.status = Status::Idle;
    let json = serde_json::to_string(&session).unwrap();
    assert!(json.contains("\"status\":\"idle\""));

    session.status = Status::Working;
    let json = serde_json::to_string(&session).unwrap();
    assert!(json.contains("\"status\":\"working\""));

    session.status = Status::NeedsAttention;
    let json = serde_json::to_string(&session).unwrap();
    assert!(json.contains("\"status\":\"needs_attention\""));
}
