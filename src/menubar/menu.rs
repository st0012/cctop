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
/// - "Idle" label, then idle sessions (dimmed)
/// - Separator
/// - "Open TUI" item
/// - "Quit cctop" item
///
/// Each session item shows: project_name (branch)
pub fn build_menu(sessions: &[Session]) -> Menu {
    let menu = Menu::new();

    // Group sessions by status
    let (needs_attention, working, idle) = group_sessions_by_status(sessions);

    // Active sessions section (needs_attention + working)
    let active_sessions: Vec<&Session> = needs_attention
        .into_iter()
        .chain(working.into_iter())
        .collect();

    if !active_sessions.is_empty() {
        for session in &active_sessions {
            let item = create_session_item(session, true);
            let _ = menu.append(&item);
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
            let item = create_session_item(session, true); // clickable to jump to session
            let _ = menu.append(&item);
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
fn create_session_item(session: &Session, _is_active: bool) -> MenuItem {
    let emoji = match session.status {
        Status::NeedsAttention => "🟡",
        Status::Working => "🟢",
        Status::Idle => "⚪",
    };
    let text = format!("{} {} ({})", emoji, session.project_name, session.branch);
    let id = format!("{}{}", ids::SESSION_PREFIX, session.session_id);

    MenuItem::with_id(id, text, true, None::<Accelerator>) // always enabled/clickable
}

/// Group sessions by their status.
///
/// Returns three vectors: (needs_attention, working, idle)
fn group_sessions_by_status(
    sessions: &[Session],
) -> (Vec<&Session>, Vec<&Session>, Vec<&Session>) {
    let mut needs_attention = Vec::new();
    let mut working = Vec::new();
    let mut idle = Vec::new();

    for session in sessions {
        match session.status {
            Status::NeedsAttention => needs_attention.push(session),
            Status::Working => working.push(session),
            Status::Idle => idle.push(session),
        }
    }

    (needs_attention, working, idle)
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
    fn test_group_sessions_by_status() {
        let sessions = vec![
            make_test_session("1", Status::Idle, "proj1", "main"),
            make_test_session("2", Status::Working, "proj2", "feature"),
            make_test_session("3", Status::NeedsAttention, "proj3", "fix"),
            make_test_session("4", Status::Idle, "proj4", "develop"),
        ];

        let (needs_attention, working, idle) = group_sessions_by_status(&sessions);

        assert_eq!(needs_attention.len(), 1);
        assert_eq!(working.len(), 1);
        assert_eq!(idle.len(), 2);

        assert_eq!(needs_attention[0].session_id, "3");
        assert_eq!(working[0].session_id, "2");
    }

    // Note: Tests for build_menu are skipped because tray-icon Menu
    // can only be created on the main thread on macOS.
    // The build_menu function is tested manually via the menubar app.
}
