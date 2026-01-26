//! TUI module for cctop.
//!
//! Provides the terminal user interface for monitoring Claude Code sessions
//! using Ratatui. Displays sessions grouped by status with keyboard navigation.

use crate::config::Config;
use crate::focus::focus_terminal;
use crate::session::{Session, Status};
use anyhow::Result;
use chrono::{DateTime, Utc};
use crossterm::{
    event::{self, Event, KeyCode, KeyEvent, KeyEventKind},
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
    ExecutableCommand,
};
use ratatui::{
    prelude::*,
    widgets::{Block, Borders, List, ListItem, ListState, Paragraph},
};
use std::fs;
use std::io::stdout;
use std::path::PathBuf;
use std::time::Duration;

/// Main application state for the TUI.
pub struct App {
    /// All loaded sessions
    sessions: Vec<Session>,
    /// Currently selected index in the flat session list
    selected_index: usize,
    /// Configuration loaded from ~/.cctop/config.toml
    config: Config,
    /// List state for ratatui
    list_state: ListState,
    /// Flag to signal the app should quit
    should_quit: bool,
}

impl App {
    /// Create a new App with the given configuration.
    pub fn new(config: Config) -> Self {
        let mut list_state = ListState::default();
        list_state.select(Some(0));

        Self {
            sessions: Vec::new(),
            selected_index: 0,
            config,
            list_state,
            should_quit: false,
        }
    }

    /// Load sessions from ~/.cctop/sessions/
    pub fn load_sessions(&mut self) {
        self.sessions = load_all_sessions().unwrap_or_default();

        // Sort by status priority, then by last_activity
        self.sessions.sort_by(|a, b| {
            let priority = |s: &Status| match s {
                Status::NeedsAttention => 0,
                Status::Working => 1,
                Status::Idle => 2,
            };
            priority(&a.status)
                .cmp(&priority(&b.status))
                .then_with(|| b.last_activity.cmp(&a.last_activity))
        });

        // Ensure selection stays valid
        if !self.sessions.is_empty() {
            if self.selected_index >= self.sessions.len() {
                self.selected_index = self.sessions.len() - 1;
            }
            self.list_state.select(Some(self.selected_index));
        } else {
            self.selected_index = 0;
            self.list_state.select(None);
        }
    }

    /// Main event loop - runs the TUI until quit.
    pub fn run(
        &mut self,
        terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
    ) -> Result<()> {
        // Cleanup stale sessions on startup
        let _ = cleanup_stale_sessions(chrono::Duration::hours(24));

        // Initial load
        self.load_sessions();

        while !self.should_quit {
            // Draw the UI
            terminal.draw(|frame| self.draw(frame))?;

            // Poll for events with 200ms timeout for auto-refresh
            if event::poll(Duration::from_millis(200))? {
                if let Event::Key(key) = event::read()? {
                    if key.kind == KeyEventKind::Press && self.handle_key(key) {
                        break;
                    }
                }
            } else {
                // No event - auto-refresh
                self.load_sessions();
            }
        }

        Ok(())
    }

    /// Render the UI to the frame.
    pub fn draw(&self, frame: &mut Frame) {
        let area = frame.area();

        // Layout: header, content, footer
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3), // header
                Constraint::Min(5),    // content
                Constraint::Length(1), // footer
            ])
            .split(area);

        self.render_header(frame, chunks[0]);
        self.render_sessions(frame, chunks[1]);
        self.render_footer(frame, chunks[2]);
    }

    /// Handle a key event. Returns true if the app should quit.
    pub fn handle_key(&mut self, key: KeyEvent) -> bool {
        match key.code {
            KeyCode::Char('q') | KeyCode::Esc => {
                self.should_quit = true;
                true
            }
            KeyCode::Char('r') => {
                self.load_sessions();
                false
            }
            KeyCode::Up | KeyCode::Char('k') => {
                self.select_previous();
                false
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.select_next();
                false
            }
            KeyCode::Enter => {
                self.focus_selected();
                false
            }
            _ => false,
        }
    }

    /// Focus the terminal window for the selected session.
    pub fn focus_selected(&self) {
        if let Some(session) = self.sessions.get(self.selected_index) {
            let _ = focus_terminal(session, &self.config);
        }
    }

    /// Select the previous session in the list.
    fn select_previous(&mut self) {
        if self.sessions.is_empty() {
            return;
        }
        if self.selected_index == 0 {
            self.selected_index = self.sessions.len() - 1;
        } else {
            self.selected_index -= 1;
        }
        self.list_state.select(Some(self.selected_index));
    }

    /// Select the next session in the list.
    fn select_next(&mut self) {
        if self.sessions.is_empty() {
            return;
        }
        if self.selected_index >= self.sessions.len() - 1 {
            self.selected_index = 0;
        } else {
            self.selected_index += 1;
        }
        self.list_state.select(Some(self.selected_index));
    }

    /// Render the header bar.
    fn render_header(&self, frame: &mut Frame, area: Rect) {
        let session_count = self.sessions.len();
        let session_text = if session_count == 1 {
            "1 session".to_string()
        } else {
            format!("{} sessions", session_count)
        };

        let title = format!(
            "  cctop{:>width$}",
            format!("{}  ", session_text),
            width = (area.width as usize).saturating_sub(10)
        );

        let header = Paragraph::new(title)
            .style(Style::default().fg(Color::White).bold())
            .block(Block::default().borders(Borders::ALL));

        frame.render_widget(header, area);
    }

    /// Render the session list grouped by status.
    fn render_sessions(&self, frame: &mut Frame, area: Rect) {
        if self.sessions.is_empty() {
            let msg =
                Paragraph::new("No active sessions\n\nStart a Claude Code session to see it here.")
                    .style(Style::default().fg(Color::DarkGray))
                    .alignment(Alignment::Center);
            frame.render_widget(msg, area);
            return;
        }

        // Group sessions by status
        let (needs_attention, working, idle) = group_sessions_by_status(&self.sessions);

        // Build list items with section headers
        let mut items: Vec<ListItem> = Vec::new();
        let mut flat_index = 0;

        // Helper to add a section
        let mut add_section = |title: &str, sessions: Vec<&Session>, color: Color| {
            if !sessions.is_empty() {
                // Add section header
                let header_line = format!("  {} ", title);
                let header_width = area.width as usize;
                let padding = header_width.saturating_sub(header_line.len() + 2);
                let header = format!("{}{}", header_line, "\u{2500}".repeat(padding));
                items.push(
                    ListItem::new(Line::from(Span::styled(
                        header,
                        Style::default().fg(Color::DarkGray),
                    )))
                    .style(Style::default()),
                );

                // Add sessions in this group
                for session in sessions {
                    let item = self.session_to_list_item(session, area.width, color, flat_index);
                    items.push(item);
                    flat_index += 1;
                }

                // Add blank line after section
                items.push(ListItem::new(""));
            }
        };

        add_section("NEEDS ATTENTION", needs_attention, Color::Yellow);
        add_section("WORKING", working, Color::Cyan);
        add_section("IDLE", idle, Color::DarkGray);

        // Create list widget - we need to track selection separately
        // because we have section headers mixed in
        let list = List::new(items)
            .highlight_style(Style::default().add_modifier(Modifier::REVERSED))
            .highlight_symbol("> ");

        // Calculate the actual list index accounting for section headers
        let actual_index = self.calculate_actual_list_index();
        let mut list_state = ListState::default();
        list_state.select(Some(actual_index));

        frame.render_stateful_widget(list, area, &mut list_state);
    }

    /// Calculate the actual list index accounting for section headers and blank lines.
    fn calculate_actual_list_index(&self) -> usize {
        if self.sessions.is_empty() {
            return 0;
        }

        let (needs_attention, working, idle) = group_sessions_by_status(&self.sessions);
        let mut offset = 0;
        let mut session_count = 0;

        // Check needs_attention section
        if !needs_attention.is_empty() {
            offset += 1; // section header
            if self.selected_index < session_count + needs_attention.len() {
                return offset + (self.selected_index - session_count);
            }
            session_count += needs_attention.len();
            offset += needs_attention.len() + 1; // sessions + blank line
        }

        // Check working section
        if !working.is_empty() {
            offset += 1; // section header
            if self.selected_index < session_count + working.len() {
                return offset + (self.selected_index - session_count);
            }
            session_count += working.len();
            offset += working.len() + 1; // sessions + blank line
        }

        // Check idle section
        if !idle.is_empty() {
            offset += 1; // section header
            if self.selected_index < session_count + idle.len() {
                return offset + (self.selected_index - session_count);
            }
        }

        offset
    }

    /// Convert a session to a list item for display.
    fn session_to_list_item(
        &self,
        session: &Session,
        width: u16,
        color: Color,
        _index: usize,
    ) -> ListItem<'static> {
        let indicator = match session.status {
            Status::NeedsAttention => "\u{2192}", // ->
            Status::Working => "\u{25C9}",        // (o)
            Status::Idle => "\u{00B7}",           // .
        };

        let time = format_relative_time(session.last_activity);

        // Format: indicator project_name branch time
        let main_line = format!(
            "  {} {:<20} {:<15} {}",
            indicator, session.project_name, session.branch, time
        );

        let prompt_line = if let Some(prompt) = &session.last_prompt {
            let max_width = (width as usize).saturating_sub(8);
            let truncated = truncate_prompt(prompt, max_width.min(60));
            format!("    \"{}\"", truncated)
        } else {
            String::new()
        };

        let content = if prompt_line.is_empty() {
            main_line
        } else {
            format!("{}\n{}", main_line, prompt_line)
        };

        ListItem::new(content).style(Style::default().fg(color))
    }

    /// Render the footer with keyboard shortcuts.
    fn render_footer(&self, frame: &mut Frame, area: Rect) {
        let footer = Paragraph::new(
            "  \u{2191}/\u{2193}: navigate   enter: jump to session   r: refresh   q: quit",
        )
        .style(Style::default().fg(Color::DarkGray));
        frame.render_widget(footer, area);
    }
}

/// Group sessions by their status.
///
/// Returns three vectors: (needs_attention, working, idle)
pub fn group_sessions_by_status(
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

/// Initialize the terminal for TUI mode.
pub fn init_terminal() -> Result<Terminal<CrosstermBackend<std::io::Stdout>>> {
    stdout().execute(EnterAlternateScreen)?;
    enable_raw_mode()?;
    let mut terminal = Terminal::new(CrosstermBackend::new(stdout()))?;
    terminal.clear()?;
    Ok(terminal)
}

/// Restore the terminal to normal mode.
pub fn restore_terminal() -> Result<()> {
    stdout().execute(LeaveAlternateScreen)?;
    disable_raw_mode()?;
    Ok(())
}

// ============================================================================
// Helper functions for session management
// ============================================================================

/// Returns the sessions directory path: ~/.cctop/sessions/
fn sessions_dir() -> Option<PathBuf> {
    dirs::home_dir().map(|home| home.join(".cctop").join("sessions"))
}

/// Load all sessions from ~/.cctop/sessions/
fn load_all_sessions() -> Result<Vec<Session>> {
    let dir = match sessions_dir() {
        Some(d) => d,
        None => return Ok(Vec::new()),
    };

    if !dir.exists() {
        return Ok(Vec::new());
    }

    let mut sessions = Vec::new();

    for entry in fs::read_dir(&dir)? {
        let entry = entry?;
        let path = entry.path();

        if path.extension().map(|e| e == "json").unwrap_or(false) {
            match Session::from_file(&path) {
                Ok(session) => sessions.push(session),
                Err(e) => eprintln!("Failed to load {}: {}", path.display(), e),
            }
        }
    }

    // Sort by last_activity descending
    sessions.sort_by(|a, b| b.last_activity.cmp(&a.last_activity));

    Ok(sessions)
}

/// Remove stale session files older than max_age.
fn cleanup_stale_sessions(max_age: chrono::Duration) -> Result<usize> {
    let dir = match sessions_dir() {
        Some(d) => d,
        None => return Ok(0),
    };

    if !dir.exists() {
        return Ok(0);
    }

    let cutoff = Utc::now() - max_age;
    let mut removed = 0;

    for entry in fs::read_dir(&dir)? {
        let entry = entry?;
        let path = entry.path();

        if path.extension().map(|e| e == "json").unwrap_or(false) {
            if let Ok(session) = Session::from_file(&path) {
                if session.last_activity < cutoff && fs::remove_file(&path).is_ok() {
                    removed += 1;
                }
            }
        }
    }

    Ok(removed)
}

/// Format a timestamp as a relative time string (e.g., "5m ago", "2h ago").
fn format_relative_time(time: DateTime<Utc>) -> String {
    let now = Utc::now();
    let duration = now.signed_duration_since(time);

    if duration.num_seconds() < 0 {
        return "just now".to_string();
    }

    let seconds = duration.num_seconds();
    let minutes = duration.num_minutes();
    let hours = duration.num_hours();
    let days = duration.num_days();

    if seconds < 60 {
        format!("{}s ago", seconds)
    } else if minutes < 60 {
        format!("{}m ago", minutes)
    } else if hours < 24 {
        format!("{}h ago", hours)
    } else {
        format!("{}d ago", days)
    }
}

/// Truncate a prompt to max_len characters, adding "..." if truncated.
fn truncate_prompt(prompt: &str, max_len: usize) -> String {
    if prompt.len() <= max_len {
        prompt.to_string()
    } else if max_len <= 3 {
        "...".to_string()
    } else {
        format!("{}...", &prompt[..max_len - 3])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::TerminalInfo;
    use chrono::Utc;

    fn make_test_session(id: &str, status: Status, project: &str) -> Session {
        Session {
            session_id: id.to_string(),
            project_path: format!("/tmp/{}", project),
            project_name: project.to_string(),
            branch: "main".to_string(),
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
            make_test_session("1", Status::Idle, "proj1"),
            make_test_session("2", Status::Working, "proj2"),
            make_test_session("3", Status::NeedsAttention, "proj3"),
            make_test_session("4", Status::Idle, "proj4"),
        ];

        let (needs_attention, working, idle) = group_sessions_by_status(&sessions);

        assert_eq!(needs_attention.len(), 1);
        assert_eq!(working.len(), 1);
        assert_eq!(idle.len(), 2);

        assert_eq!(needs_attention[0].session_id, "3");
        assert_eq!(working[0].session_id, "2");
    }

    #[test]
    fn test_app_new() {
        let config = Config::default();
        let app = App::new(config);

        assert!(app.sessions.is_empty());
        assert_eq!(app.selected_index, 0);
        assert!(!app.should_quit);
    }

    #[test]
    fn test_select_next_empty() {
        let config = Config::default();
        let mut app = App::new(config);

        app.select_next();
        assert_eq!(app.selected_index, 0);
    }

    #[test]
    fn test_select_previous_empty() {
        let config = Config::default();
        let mut app = App::new(config);

        app.select_previous();
        assert_eq!(app.selected_index, 0);
    }

    #[test]
    fn test_select_navigation_wraps() {
        let config = Config::default();
        let mut app = App::new(config);

        // Manually add sessions for testing
        app.sessions = vec![
            make_test_session("1", Status::Idle, "proj1"),
            make_test_session("2", Status::Idle, "proj2"),
            make_test_session("3", Status::Idle, "proj3"),
        ];
        app.selected_index = 0;

        // Navigate up from first should wrap to last
        app.select_previous();
        assert_eq!(app.selected_index, 2);

        // Navigate down from last should wrap to first
        app.select_next();
        assert_eq!(app.selected_index, 0);
    }

    #[test]
    fn test_handle_key_quit() {
        let config = Config::default();
        let mut app = App::new(config);

        let key = KeyEvent::new(KeyCode::Char('q'), crossterm::event::KeyModifiers::NONE);
        let should_quit = app.handle_key(key);

        assert!(should_quit);
        assert!(app.should_quit);
    }

    #[test]
    fn test_handle_key_navigation() {
        let config = Config::default();
        let mut app = App::new(config);

        app.sessions = vec![
            make_test_session("1", Status::Idle, "proj1"),
            make_test_session("2", Status::Idle, "proj2"),
        ];
        app.selected_index = 0;

        // Down arrow
        let key = KeyEvent::new(KeyCode::Down, crossterm::event::KeyModifiers::NONE);
        let should_quit = app.handle_key(key);

        assert!(!should_quit);
        assert_eq!(app.selected_index, 1);

        // Up arrow
        let key = KeyEvent::new(KeyCode::Up, crossterm::event::KeyModifiers::NONE);
        app.handle_key(key);

        assert_eq!(app.selected_index, 0);
    }

    #[test]
    fn test_handle_key_vim_navigation() {
        let config = Config::default();
        let mut app = App::new(config);

        app.sessions = vec![
            make_test_session("1", Status::Idle, "proj1"),
            make_test_session("2", Status::Idle, "proj2"),
        ];
        app.selected_index = 0;

        // j for down
        let key = KeyEvent::new(KeyCode::Char('j'), crossterm::event::KeyModifiers::NONE);
        app.handle_key(key);
        assert_eq!(app.selected_index, 1);

        // k for up
        let key = KeyEvent::new(KeyCode::Char('k'), crossterm::event::KeyModifiers::NONE);
        app.handle_key(key);
        assert_eq!(app.selected_index, 0);
    }

    #[test]
    fn test_format_relative_time() {
        use chrono::Duration;

        let now = Utc::now();

        assert_eq!(format_relative_time(now - Duration::seconds(30)), "30s ago");
        assert_eq!(format_relative_time(now - Duration::minutes(5)), "5m ago");
        assert_eq!(format_relative_time(now - Duration::hours(2)), "2h ago");
        assert_eq!(format_relative_time(now - Duration::days(3)), "3d ago");
    }

    #[test]
    fn test_truncate_prompt() {
        assert_eq!(truncate_prompt("short", 50), "short");
        assert_eq!(
            truncate_prompt("a".repeat(100).as_str(), 50),
            format!("{}...", "a".repeat(47))
        );
        assert_eq!(truncate_prompt("hello", 3), "...");
        assert_eq!(truncate_prompt("hello", 8), "hello");
    }
}
