//! File watcher for monitoring session directory changes.
//!
//! Uses the `notify` crate to watch `~/.cctop/sessions/` for file changes
//! and reloads sessions when files are created, modified, or deleted.

use crate::session::{load_live_sessions, Session};
use anyhow::{Context, Result};
use notify::{Config, Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, TryRecvError};

/// Watches the sessions directory for changes and provides updated sessions.
pub struct SessionWatcher {
    /// The watcher instance (kept alive to maintain the watch)
    _watcher: RecommendedWatcher,
    /// Receiver for file system events
    receiver: Receiver<Result<Event, notify::Error>>,
    /// Path to the sessions directory
    sessions_dir: PathBuf,
}

impl SessionWatcher {
    /// Create a new watcher for the sessions directory.
    ///
    /// The watcher monitors `~/.cctop/sessions/` for file changes.
    /// If the directory does not exist, it will be created.
    pub fn new() -> Result<Self> {
        let sessions_dir = dirs::home_dir()
            .context("Could not determine home directory")?
            .join(".cctop")
            .join("sessions");

        // Ensure the sessions directory exists
        if !sessions_dir.exists() {
            std::fs::create_dir_all(&sessions_dir)
                .with_context(|| format!("Failed to create sessions directory: {:?}", sessions_dir))?;
        }

        // Create a channel for receiving events
        let (tx, rx) = channel();

        // Create the watcher with a channel-based event handler
        let mut watcher = RecommendedWatcher::new(
            move |res| {
                // Send events to the channel, ignoring send errors
                // (receiver may be dropped)
                let _ = tx.send(res);
            },
            Config::default(),
        )
        .context("Failed to create file watcher")?;

        // Start watching the sessions directory
        watcher
            .watch(&sessions_dir, RecursiveMode::NonRecursive)
            .with_context(|| format!("Failed to watch sessions directory: {:?}", sessions_dir))?;

        Ok(Self {
            _watcher: watcher,
            receiver: rx,
            sessions_dir,
        })
    }

    /// Check if there are pending changes and return updated sessions if so.
    ///
    /// This method is non-blocking. It drains all pending events from the
    /// watcher and, if any relevant changes occurred, reloads all sessions.
    ///
    /// Returns `Some(sessions)` if there were changes, `None` otherwise.
    pub fn poll_changes(&mut self) -> Option<Vec<Session>> {
        let mut has_changes = false;

        // Drain all pending events from the channel
        loop {
            match self.receiver.try_recv() {
                Ok(Ok(event)) => {
                    // Check if this is a relevant event (create, modify, or remove)
                    if Self::is_relevant_event(&event) {
                        has_changes = true;
                    }
                }
                Ok(Err(e)) => {
                    // Log watcher errors but continue
                    eprintln!("File watcher error: {}", e);
                }
                Err(TryRecvError::Empty) => {
                    // No more events in the channel
                    break;
                }
                Err(TryRecvError::Disconnected) => {
                    // Channel disconnected, watcher may have been dropped
                    eprintln!("File watcher channel disconnected");
                    break;
                }
            }
        }

        if has_changes {
            // Reload all sessions, filtering out dead ones by PID
            match load_live_sessions(&self.sessions_dir) {
                Ok(sessions) => Some(sessions),
                Err(e) => {
                    eprintln!("Failed to reload sessions: {}", e);
                    None
                }
            }
        } else {
            None
        }
    }

    /// Check if an event is relevant (i.e., should trigger a reload).
    ///
    /// We care about:
    /// - Create events (new session files)
    /// - Modify events (session updates)
    /// - Remove events (session ended)
    fn is_relevant_event(event: &Event) -> bool {
        use notify::EventKind;

        matches!(
            event.kind,
            EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{Status, TerminalInfo};
    use std::fs;
    use std::thread;
    use std::time::Duration;
    use tempfile::tempdir;

    fn create_test_session(session_id: &str) -> Session {
        Session {
            session_id: session_id.to_string(),
            project_path: "/nonexistent/test/projects/testproj".to_string(),
            project_name: "testproj".to_string(),
            branch: "main".to_string(),
            status: Status::Idle,
            last_prompt: Some("Test prompt".to_string()),
            last_activity: chrono::Utc::now(),
            started_at: chrono::Utc::now(),
            terminal: TerminalInfo {
                program: "test".to_string(),
                session_id: None,
                tty: None,
            },
            pid: None,
            last_tool: None,
            last_tool_detail: None,
            notification_message: None,
            context_compacted: false,
        }
    }

    #[test]
    fn test_is_relevant_event() {
        use notify::event::{CreateKind, ModifyKind, RemoveKind};
        use notify::EventKind;

        // Create event should be relevant
        let create_event = Event {
            kind: EventKind::Create(CreateKind::File),
            paths: vec![],
            attrs: Default::default(),
        };
        assert!(SessionWatcher::is_relevant_event(&create_event));

        // Modify event should be relevant
        let modify_event = Event {
            kind: EventKind::Modify(ModifyKind::Data(notify::event::DataChange::Content)),
            paths: vec![],
            attrs: Default::default(),
        };
        assert!(SessionWatcher::is_relevant_event(&modify_event));

        // Remove event should be relevant
        let remove_event = Event {
            kind: EventKind::Remove(RemoveKind::File),
            paths: vec![],
            attrs: Default::default(),
        };
        assert!(SessionWatcher::is_relevant_event(&remove_event));

        // Access event should not be relevant
        let access_event = Event {
            kind: EventKind::Access(notify::event::AccessKind::Read),
            paths: vec![],
            attrs: Default::default(),
        };
        assert!(!SessionWatcher::is_relevant_event(&access_event));
    }

    #[test]
    fn test_watcher_detects_new_file() {
        // This test creates a temporary directory structure and tests file watching
        let temp_dir = tempdir().unwrap();
        let sessions_dir = temp_dir.path().join(".cctop").join("sessions");
        fs::create_dir_all(&sessions_dir).unwrap();

        // Create a watcher manually for the temp directory
        let (tx, rx) = channel();
        let mut watcher = RecommendedWatcher::new(
            move |res| {
                let _ = tx.send(res);
            },
            Config::default(),
        )
        .unwrap();

        watcher
            .watch(&sessions_dir, RecursiveMode::NonRecursive)
            .unwrap();

        // Create a session file
        let session = create_test_session("test-watcher");
        session.write_to_dir(&sessions_dir).unwrap();

        // Give the watcher time to detect the change
        thread::sleep(Duration::from_millis(100));

        // Check that we received at least one event
        let mut received_event = false;
        while let Ok(result) = rx.try_recv() {
            if result.is_ok() {
                received_event = true;
            }
        }

        assert!(received_event, "Should have received a file system event");
    }
}
