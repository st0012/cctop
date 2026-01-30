//! Menu building for the cctop menubar app.
//!
//! Creates a tray menu displaying Claude Code sessions grouped by status.

use crate::session::{Session, Status};
use tray_icon::menu::{accelerator::Accelerator, Menu, MenuItem, PredefinedMenuItem};

/// Menu item IDs for handling menu events.
pub mod ids {
    /// Prefix for session menu items (followed by session_id).
    pub const SESSION_PREFIX: &str = "session:";
    /// ID for the "Quit" menu item.
    pub const QUIT: &str = "quit";
}

/// Build the tray menu from a list of sessions.
///
/// Menu structure:
/// - Active sessions (needs_attention + working) at top
/// - Separator
/// - "Idle" label, then idle sessions
/// - Separator
/// - "Quit cctop" item
///
/// Each session item shows: emoji project_name (branch)
pub fn build_menu(sessions: &[Session]) -> Menu {
    let menu = Menu::new();

    // Group sessions into active (needs_attention, working) and idle
    let (active_sessions, idle) = partition_sessions_by_activity(sessions);

    if !active_sessions.is_empty() {
        for session in &active_sessions {
            let _ = menu.append(&create_session_item(session));
        }
    } else {
        // Show "No active sessions" when there are no active sessions
        let no_active = MenuItem::with_id(
            "no_active",
            "No active sessions",
            false, // disabled
            None::<Accelerator>,
        );
        let _ = menu.append(&no_active);
    }

    // Separator before idle section
    let _ = menu.append(&PredefinedMenuItem::separator());

    // Idle section
    if !idle.is_empty() {
        // "Idle" label (disabled, acts as section header)
        let idle_label = MenuItem::with_id(
            "idle_label",
            "Idle",
            false, // disabled - acts as label
            None::<Accelerator>,
        );
        let _ = menu.append(&idle_label);

        for session in &idle {
            let _ = menu.append(&create_session_item(session));
        }
    }

    // Separator before quit
    let _ = menu.append(&PredefinedMenuItem::separator());

    // Quit item
    let quit = MenuItem::with_id(ids::QUIT, "Quit cctop", true, None::<Accelerator>);
    let _ = menu.append(&quit);

    menu
}

/// Create a menu item for a session.
///
/// Format: "emoji project_name (branch)"
fn create_session_item(session: &Session) -> MenuItem {
    let emoji = match session.status {
        Status::NeedsAttention => "🟡",
        Status::Working => "🟢",
        Status::Idle => "⚪",
    };
    let text = format!("{} {} ({})", emoji, session.project_name, session.branch);
    let id = format!("{}{}", ids::SESSION_PREFIX, session.session_id);

    MenuItem::with_id(id, text, true, None::<Accelerator>)
}

/// Partition sessions into active (needs_attention + working) and idle.
///
/// Active sessions are sorted with needs_attention first, then working.
fn partition_sessions_by_activity(sessions: &[Session]) -> (Vec<&Session>, Vec<&Session>) {
    let mut active = Vec::new();
    let mut idle = Vec::new();

    // First pass: collect needs_attention (highest priority)
    for session in sessions {
        if session.status == Status::NeedsAttention {
            active.push(session);
        }
    }

    // Second pass: collect working sessions
    for session in sessions {
        if session.status == Status::Working {
            active.push(session);
        }
    }

    // Third pass: collect idle sessions
    for session in sessions {
        if session.status == Status::Idle {
            idle.push(session);
        }
    }

    (active, idle)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::TerminalInfo;
    use chrono::Utc;

    fn make_test_session(id: &str, status: Status, project: &str, branch: &str) -> Session {
        Session {
            session_id: id.to_string(),
            project_path: format!("/tmp/{}", project),
            project_name: project.to_string(),
            branch: branch.to_string(),
            status,
            last_prompt: Some("Test prompt".to_string()),
            last_activity: Utc::now(),
            started_at: Utc::now(),
            terminal: TerminalInfo {
                program: "test".to_string(),
                session_id: None,
                tty: None,
            },
        }
    }

    #[test]
    fn test_partition_sessions_by_activity() {
        let sessions = vec![
            make_test_session("1", Status::Idle, "proj1", "main"),
            make_test_session("2", Status::Working, "proj2", "feature"),
            make_test_session("3", Status::NeedsAttention, "proj3", "fix"),
            make_test_session("4", Status::Idle, "proj4", "develop"),
        ];

        let (active, idle) = partition_sessions_by_activity(&sessions);

        assert_eq!(active.len(), 2);
        assert_eq!(idle.len(), 2);

        // Needs attention should come first, then working
        assert_eq!(active[0].session_id, "3");
        assert_eq!(active[1].session_id, "2");
    }

    // Note: Tests for build_menu are skipped because tray-icon Menu
    // can only be created on the main thread on macOS.
    // The build_menu function is tested manually via the menubar app.
}
