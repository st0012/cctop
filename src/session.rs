//! Session data model and file I/O for cctop.
//!
//! Defines the Session struct that represents a Claude Code session,
//! and provides functions for reading/writing session files.

use anyhow::{Context, Result};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

/// Session status indicating the current state of a Claude Code session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    /// Session is waiting for user input
    Idle,
    /// Session is actively processing (running tools, generating response)
    Working,
    /// Session requires user attention (permission prompt, etc.)
    NeedsAttention,
}

impl Status {
    /// Returns the visual indicator character for this status.
    /// - `->` for needs_attention (red)
    /// - `*` for working (blue)
    /// - `.` for idle (gray)
    pub fn indicator(&self) -> &'static str {
        match self {
            Status::Idle => "\u{00B7}",           // .
            Status::Working => "\u{25C9}",        // *
            Status::NeedsAttention => "\u{2192}", // ->
        }
    }

    /// Determines the status from a hook event name.
    ///
    /// - SessionStart -> Idle
    /// - UserPromptSubmit -> Working
    /// - PreToolUse -> Working
    /// - PostToolUse -> Working
    /// - Stop -> Idle
    /// - Notification -> NeedsAttention
    pub fn from_hook(event: &str) -> Status {
        match event {
            "SessionStart" => Status::Idle,
            "UserPromptSubmit" => Status::Working,
            "PreToolUse" => Status::Working,
            "PostToolUse" => Status::Working,
            "Stop" => Status::Idle,
            "Notification" => Status::NeedsAttention,
            _ => Status::Idle,
        }
    }

    /// Alias for from_hook for backwards compatibility
    pub fn from_hook_event(event: &str) -> Status {
        Self::from_hook(event)
    }
}

/// Terminal information for window focusing.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TerminalInfo {
    /// Terminal program name (e.g., "iTerm.app", "vscode", "kitty")
    pub program: String,
    /// Terminal-specific session ID (iTerm2 or Kitty)
    pub session_id: Option<String>,
    /// TTY path (e.g., "/dev/ttys003")
    pub tty: Option<String>,
}

/// A Claude Code session with all its metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    /// Unique session identifier from Claude Code
    pub session_id: String,
    /// Full path to the project directory
    pub project_path: String,
    /// Project name (last component of project_path)
    pub project_name: String,
    /// Current git branch
    pub branch: String,
    /// Current session status
    pub status: Status,
    /// Last prompt submitted by the user
    pub last_prompt: Option<String>,
    /// Timestamp of last activity
    pub last_activity: DateTime<Utc>,
    /// Timestamp when session started
    pub started_at: DateTime<Utc>,
    /// Terminal information for window focusing
    pub terminal: TerminalInfo,
}

impl Session {
    /// Creates a new session with the given ID and project path.
    pub fn new(
        session_id: String,
        project_path: String,
        branch: String,
        terminal: TerminalInfo,
    ) -> Self {
        let project_name = extract_project_name(&project_path);
        let now = Utc::now();

        Self {
            session_id,
            project_path,
            project_name,
            branch,
            status: Status::Idle,
            last_prompt: None,
            last_activity: now,
            started_at: now,
            terminal,
        }
    }

    /// Parse a Session from a JSON string.
    pub fn from_json(json: &str) -> Result<Session> {
        serde_json::from_str(json).context("Failed to parse session JSON")
    }

    /// Loads a session from a JSON file.
    pub fn from_file(path: &Path) -> Result<Self> {
        let contents = fs::read_to_string(path)
            .with_context(|| format!("Failed to read session file: {:?}", path))?;
        Self::from_json(&contents)
    }

    /// Load all sessions from a directory.
    pub fn load_all(sessions_dir: &Path) -> Result<Vec<Session>> {
        let mut sessions = Vec::new();

        if !sessions_dir.exists() {
            return Ok(sessions);
        }

        let entries = fs::read_dir(sessions_dir)
            .with_context(|| format!("Failed to read sessions directory: {:?}", sessions_dir))?;

        for entry in entries {
            let entry = entry?;
            let path = entry.path();

            // Skip non-JSON files
            if path.extension().map(|e| e != "json").unwrap_or(true) {
                continue;
            }

            // Skip temp files (ending in .json.tmp)
            if path
                .file_name()
                .map(|n| n.to_string_lossy().ends_with(".tmp"))
                .unwrap_or(false)
            {
                continue;
            }

            match Session::from_file(&path) {
                Ok(session) => sessions.push(session),
                Err(e) => {
                    eprintln!("Warning: Failed to load session file {:?}: {}", path, e);
                }
            }
        }

        Ok(sessions)
    }

    /// Writes the session to a JSON file atomically.
    ///
    /// Writes to a temporary file first, then renames to the final path
    /// to ensure atomic writes and avoid partial files.
    pub fn write_to_file(&self, path: &Path) -> Result<()> {
        // Ensure parent directory exists
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("Failed to create directory: {:?}", parent))?;
        }

        let json = serde_json::to_string_pretty(self).context("Failed to serialize session")?;
        let temp_path = path.with_extension("json.tmp");

        // Write to temp file
        fs::write(&temp_path, &json)
            .with_context(|| format!("Failed to write temp file: {:?}", temp_path))?;

        // Atomic rename
        fs::rename(&temp_path, path)
            .with_context(|| format!("Failed to rename temp file to {:?}", path))?;

        Ok(())
    }

    /// Write this session to a directory using atomic write (temp file + rename).
    pub fn write_to_dir(&self, sessions_dir: &Path) -> Result<()> {
        let path = self.file_path(sessions_dir);
        self.write_to_file(&path)
    }

    /// Remove this session's file from a directory.
    pub fn remove_from_dir(&self, sessions_dir: &Path) -> Result<()> {
        let path = self.file_path(sessions_dir);

        if path.exists() {
            fs::remove_file(&path)
                .with_context(|| format!("Failed to remove session file: {:?}", path))?;
        }

        Ok(())
    }

    /// Returns the session file path for the given sessions directory.
    pub fn file_path(&self, sessions_dir: &Path) -> std::path::PathBuf {
        sessions_dir.join(format!("{}.json", self.session_id))
    }
}

/// Clean up sessions older than max_age.
pub fn cleanup_stale_sessions(sessions_dir: &Path, max_age: Duration) -> Result<()> {
    if !sessions_dir.exists() {
        return Ok(());
    }

    let now = Utc::now();
    let sessions = Session::load_all(sessions_dir)?;

    for session in sessions {
        if now.signed_duration_since(session.last_activity) > max_age {
            eprintln!(
                "Removing stale session: {} (last activity: {})",
                session.session_id, session.last_activity
            );
            session.remove_from_dir(sessions_dir)?;
        }
    }

    Ok(())
}

/// Truncate a prompt string to max_len, adding "..." if truncated.
pub fn truncate_prompt(prompt: &str, max_len: usize) -> String {
    if prompt.len() <= max_len {
        prompt.to_string()
    } else if max_len <= 3 {
        ".".repeat(max_len)
    } else {
        format!("{}...", &prompt[..max_len - 3])
    }
}

/// Format a datetime as relative time (e.g., "5m ago", "2h ago", "12s ago").
pub fn format_relative_time(datetime: DateTime<Utc>) -> String {
    let now = Utc::now();
    let duration = now.signed_duration_since(datetime);

    if duration.num_seconds() < 0 {
        return "just now".to_string();
    }

    let seconds = duration.num_seconds();
    let minutes = duration.num_minutes();
    let hours = duration.num_hours();
    let days = duration.num_days();

    if days > 0 {
        format!("{}d ago", days)
    } else if hours > 0 {
        format!("{}h ago", hours)
    } else if minutes > 0 {
        format!("{}m ago", minutes)
    } else {
        format!("{}s ago", seconds)
    }
}

/// Extracts the project name from a path (last component).
pub fn extract_project_name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("unknown")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn create_test_session(session_id: &str) -> Session {
        Session {
            session_id: session_id.to_string(),
            project_path: "/Users/test/projects/myproject".to_string(),
            project_name: "myproject".to_string(),
            branch: "main".to_string(),
            status: Status::Idle,
            last_prompt: Some("Fix the bug".to_string()),
            last_activity: Utc::now(),
            started_at: Utc::now(),
            terminal: TerminalInfo {
                program: "iTerm.app".to_string(),
                session_id: Some("w0t0p0:12345".to_string()),
                tty: Some("/dev/ttys003".to_string()),
            },
        }
    }

    #[test]
    fn test_status_indicator() {
        assert_eq!(Status::Idle.indicator(), "\u{00B7}");
        assert_eq!(Status::Working.indicator(), "\u{25C9}");
        assert_eq!(Status::NeedsAttention.indicator(), "\u{2192}");
    }

    #[test]
    fn test_status_from_hook() {
        assert_eq!(Status::from_hook("SessionStart"), Status::Idle);
        assert_eq!(Status::from_hook("UserPromptSubmit"), Status::Working);
        assert_eq!(Status::from_hook("PreToolUse"), Status::Working);
        assert_eq!(Status::from_hook("PostToolUse"), Status::Working);
        assert_eq!(Status::from_hook("Stop"), Status::Idle);
        assert_eq!(Status::from_hook("Notification"), Status::NeedsAttention);
        assert_eq!(Status::from_hook("Unknown"), Status::Idle);
    }

    #[test]
    fn test_status_from_hook_event() {
        // Test backwards compatibility alias
        assert_eq!(Status::from_hook_event("SessionStart"), Status::Idle);
        assert_eq!(Status::from_hook_event("UserPromptSubmit"), Status::Working);
        assert_eq!(Status::from_hook_event("PreToolUse"), Status::Working);
        assert_eq!(Status::from_hook_event("PostToolUse"), Status::Working);
        assert_eq!(Status::from_hook_event("Stop"), Status::Idle);
        assert_eq!(Status::from_hook_event("Unknown"), Status::Idle);
    }

    #[test]
    fn test_session_from_json() {
        let json = r#"{
            "session_id": "abc123",
            "project_path": "/tmp/test",
            "project_name": "test",
            "branch": "main",
            "status": "working",
            "last_prompt": "Fix the bug",
            "last_activity": "2026-01-25T22:48:00Z",
            "started_at": "2026-01-25T22:30:00Z",
            "terminal": {
                "program": "iTerm.app",
                "session_id": "w0t0p0:12345",
                "tty": "/dev/ttys003"
            }
        }"#;

        let session = Session::from_json(json).unwrap();
        assert_eq!(session.session_id, "abc123");
        assert_eq!(session.project_path, "/tmp/test");
        assert_eq!(session.project_name, "test");
        assert_eq!(session.branch, "main");
        assert_eq!(session.status, Status::Working);
        assert_eq!(session.last_prompt, Some("Fix the bug".to_string()));
        assert_eq!(session.terminal.program, "iTerm.app");
    }

    #[test]
    fn test_session_from_json_with_null_prompt() {
        let json = r#"{
            "session_id": "abc123",
            "project_path": "/tmp/test",
            "project_name": "test",
            "branch": "main",
            "status": "idle",
            "last_prompt": null,
            "last_activity": "2026-01-25T22:48:00Z",
            "started_at": "2026-01-25T22:30:00Z",
            "terminal": {
                "program": "vscode",
                "session_id": null,
                "tty": null
            }
        }"#;

        let session = Session::from_json(json).unwrap();
        assert_eq!(session.last_prompt, None);
        assert_eq!(session.terminal.session_id, None);
    }

    #[test]
    fn test_session_from_json_invalid() {
        let json = "not valid json";
        let result = Session::from_json(json);
        assert!(result.is_err());
    }

    #[test]
    fn test_truncate_prompt() {
        // Short prompt - no truncation
        assert_eq!(truncate_prompt("Hello", 50), "Hello");

        // Exact length - no truncation
        assert_eq!(truncate_prompt("Hello", 5), "Hello");

        // Long prompt - truncated with ...
        let long = "a".repeat(100);
        let truncated = truncate_prompt(&long, 50);
        assert_eq!(truncated.len(), 50);
        assert!(truncated.ends_with("..."));
        assert_eq!(&truncated[..47], "a".repeat(47));

        // Edge case: max_len <= 3
        assert_eq!(truncate_prompt("Hello", 3), "...");
        assert_eq!(truncate_prompt("Hello", 2), "..");
        assert_eq!(truncate_prompt("Hello", 1), ".");
    }

    #[test]
    fn test_format_relative_time() {
        // 5 minutes ago
        let past = Utc::now() - Duration::minutes(5);
        assert_eq!(format_relative_time(past), "5m ago");

        // 2 hours ago
        let past = Utc::now() - Duration::hours(2);
        assert_eq!(format_relative_time(past), "2h ago");

        // 12 seconds ago
        let past = Utc::now() - Duration::seconds(12);
        assert_eq!(format_relative_time(past), "12s ago");

        // 3 days ago
        let past = Utc::now() - Duration::days(3);
        assert_eq!(format_relative_time(past), "3d ago");

        // Future time (edge case)
        let future = Utc::now() + Duration::minutes(5);
        assert_eq!(format_relative_time(future), "just now");
    }

    #[test]
    fn test_extract_project_name() {
        assert_eq!(extract_project_name("/Users/st0012/projects/irb"), "irb");
        assert_eq!(extract_project_name("/tmp/"), "tmp");
        assert_eq!(extract_project_name("/"), "unknown");
        assert_eq!(extract_project_name("simple"), "simple");
        assert_eq!(
            extract_project_name("/a/b/c/deep/nested/project"),
            "project"
        );
    }

    #[test]
    fn test_session_new() {
        let terminal = TerminalInfo {
            program: "iTerm.app".to_string(),
            session_id: Some("w0t0p0:123".to_string()),
            tty: Some("/dev/ttys003".to_string()),
        };
        let session = Session::new(
            "abc123".to_string(),
            "/Users/st0012/projects/irb".to_string(),
            "main".to_string(),
            terminal,
        );

        assert_eq!(session.session_id, "abc123");
        assert_eq!(session.project_path, "/Users/st0012/projects/irb");
        assert_eq!(session.project_name, "irb");
        assert_eq!(session.branch, "main");
        assert_eq!(session.status, Status::Idle);
        assert!(session.last_prompt.is_none());
    }

    #[test]
    fn test_session_serialization() {
        let terminal = TerminalInfo {
            program: "vscode".to_string(),
            session_id: None,
            tty: None,
        };
        let session = Session::new(
            "test-123".to_string(),
            "/tmp/test".to_string(),
            "main".to_string(),
            terminal,
        );

        let json = serde_json::to_string(&session).unwrap();
        let deserialized: Session = serde_json::from_str(&json).unwrap();

        assert_eq!(session.session_id, deserialized.session_id);
        assert_eq!(session.project_name, deserialized.project_name);
    }

    #[test]
    fn test_session_file_path() {
        let terminal = TerminalInfo::default();
        let session = Session::new(
            "abc-123".to_string(),
            "/tmp".to_string(),
            "main".to_string(),
            terminal,
        );

        let sessions_dir = Path::new("/Users/test/.cctop/sessions");
        let file_path = session.file_path(sessions_dir);

        assert_eq!(
            file_path,
            Path::new("/Users/test/.cctop/sessions/abc-123.json")
        );
    }

    #[test]
    fn test_write_and_read_session_file() {
        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path().join("sessions");

        let session = create_test_session("test123");
        session.write_to_dir(&sessions_dir).unwrap();

        // Verify file exists
        let file_path = sessions_dir.join("test123.json");
        assert!(file_path.exists());

        // Load all sessions
        let sessions = Session::load_all(&sessions_dir).unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session_id, "test123");
        assert_eq!(sessions[0].project_name, "myproject");
    }

    #[test]
    fn test_load_all_empty_directory() {
        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path().join("sessions");

        // Directory doesn't exist yet
        let sessions = Session::load_all(&sessions_dir).unwrap();
        assert!(sessions.is_empty());

        // Create empty directory
        fs::create_dir_all(&sessions_dir).unwrap();
        let sessions = Session::load_all(&sessions_dir).unwrap();
        assert!(sessions.is_empty());
    }

    #[test]
    fn test_load_all_skips_invalid_files() {
        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path().join("sessions");
        fs::create_dir_all(&sessions_dir).unwrap();

        // Write a valid session
        let session = create_test_session("valid");
        session.write_to_dir(&sessions_dir).unwrap();

        // Write an invalid JSON file
        fs::write(sessions_dir.join("invalid.json"), "not valid json").unwrap();

        // Write a non-JSON file
        fs::write(sessions_dir.join("readme.txt"), "just a text file").unwrap();

        // Write a temp file (should be skipped)
        fs::write(sessions_dir.join("temp.json.tmp"), "{}").unwrap();

        let sessions = Session::load_all(&sessions_dir).unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session_id, "valid");
    }

    #[test]
    fn test_remove_session_file() {
        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path().join("sessions");

        let session = create_test_session("to_remove");
        session.write_to_dir(&sessions_dir).unwrap();

        let file_path = sessions_dir.join("to_remove.json");
        assert!(file_path.exists());

        session.remove_from_dir(&sessions_dir).unwrap();
        assert!(!file_path.exists());
    }

    #[test]
    fn test_remove_nonexistent_session_file() {
        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path().join("sessions");
        fs::create_dir_all(&sessions_dir).unwrap();

        let session = create_test_session("nonexistent");
        // Should not error when file doesn't exist
        session.remove_from_dir(&sessions_dir).unwrap();
    }

    #[test]
    fn test_stale_session_cleanup() {
        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path().join("sessions");

        // Create a fresh session
        let mut fresh_session = create_test_session("fresh");
        fresh_session.last_activity = Utc::now();
        fresh_session.write_to_dir(&sessions_dir).unwrap();

        // Create an old session (25 hours ago)
        let mut old_session = create_test_session("old");
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
    fn test_stale_session_cleanup_empty_dir() {
        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path().join("nonexistent");

        // Should not error on non-existent directory
        cleanup_stale_sessions(&sessions_dir, Duration::hours(24)).unwrap();
    }

    #[test]
    fn test_session_serialization_roundtrip() {
        let original = create_test_session("roundtrip");
        let json = serde_json::to_string(&original).unwrap();
        let parsed = Session::from_json(&json).unwrap();

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
    fn test_status_serde() {
        // Test that status serializes to snake_case
        let session = create_test_session("status_test");
        let json = serde_json::to_string(&session).unwrap();
        assert!(json.contains("\"status\":\"idle\""));

        // Test needs_attention serialization
        let mut session = create_test_session("attention");
        session.status = Status::NeedsAttention;
        let json = serde_json::to_string(&session).unwrap();
        assert!(json.contains("\"status\":\"needs_attention\""));
    }

    #[test]
    fn test_atomic_write_no_partial_files() {
        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path().join("sessions");

        let session = create_test_session("atomic");
        session.write_to_dir(&sessions_dir).unwrap();

        // Verify no temp file remains
        let temp_path = sessions_dir.join("atomic.json.tmp");
        assert!(!temp_path.exists());

        // Verify final file exists
        let final_path = sessions_dir.join("atomic.json");
        assert!(final_path.exists());
    }

    #[test]
    fn test_multiple_sessions_load_all() {
        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path().join("sessions");

        // Create multiple sessions
        for i in 0..5 {
            let session = create_test_session(&format!("session-{}", i));
            session.write_to_dir(&sessions_dir).unwrap();
        }

        let sessions = Session::load_all(&sessions_dir).unwrap();
        assert_eq!(sessions.len(), 5);
    }
}
