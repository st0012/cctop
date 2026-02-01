//! Menu building for the cctop menubar app.
//!
//! Creates a tray menu displaying Claude Code sessions grouped by status.

use crate::session::{GroupedSessions, Session, Status};
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
/// - "Needs Attention" section (if any)
/// - "Working" section (if any)
/// - "Idle" section (if any)
/// - Separator
/// - "Quit cctop" item
///
/// Each session item shows: emoji project_name (branch)
pub fn build_menu(sessions: &[Session]) -> Menu {
    let menu = Menu::new();

    // Group sessions by status
    let grouped = GroupedSessions::from_sessions(sessions);
    let (needs_attention, working, idle) = grouped.as_tuple();

    let mut has_any_sessions = false;

    // Needs Attention section
    if !needs_attention.is_empty() {
        has_any_sessions = true;
        let label = MenuItem::with_id("label_attention", "Needs Attention", false, None::<Accelerator>);
        let _ = menu.append(&label);
        for session in &needs_attention {
            let _ = menu.append(&create_session_item(session));
        }
    }

    // Working section
    if !working.is_empty() {
        has_any_sessions = true;
        let label = MenuItem::with_id("label_working", "Working", false, None::<Accelerator>);
        let _ = menu.append(&label);
        for session in &working {
            let _ = menu.append(&create_session_item(session));
        }
    }

    // Idle section
    if !idle.is_empty() {
        has_any_sessions = true;
        let label = MenuItem::with_id("label_idle", "Idle", false, None::<Accelerator>);
        let _ = menu.append(&label);
        for session in &idle {
            let _ = menu.append(&create_session_item(session));
        }
    }

    if !has_any_sessions {
        let no_sessions = MenuItem::with_id("no_sessions", "No sessions", false, None::<Accelerator>);
        let _ = menu.append(&no_sessions);
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::TerminalInfo;
    use chrono::Utc;

    fn make_test_session(id: &str, status: Status, project: &str, branch: &str) -> Session {
        Session {
            session_id: id.to_string(),
            project_path: format!("/nonexistent/test/projects/{}", project),
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
            pid: None,
        }
    }

    #[test]
    fn test_grouped_sessions() {
        let sessions = vec![
            make_test_session("1", Status::Idle, "proj1", "main"),
            make_test_session("2", Status::Working, "proj2", "feature"),
            make_test_session("3", Status::NeedsAttention, "proj3", "fix"),
            make_test_session("4", Status::Idle, "proj4", "develop"),
        ];

        let grouped = GroupedSessions::from_sessions(&sessions);

        assert_eq!(grouped.needs_attention.len(), 1);
        assert_eq!(grouped.working.len(), 1);
        assert_eq!(grouped.idle.len(), 2);

        assert_eq!(grouped.needs_attention[0].session_id, "3");
        assert_eq!(grouped.working[0].session_id, "2");
    }

    // Note: Tests for build_menu are skipped because tray-icon Menu
    // can only be created on the main thread on macOS.
    // The build_menu function is tested manually via the menubar app.
}
