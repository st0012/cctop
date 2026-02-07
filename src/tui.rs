//! TUI module for cctop.
//!
//! Provides the terminal user interface for monitoring Claude Code sessions
//! using Ratatui. Displays sessions grouped by status with keyboard navigation.

use crate::config::Config;
use crate::focus::focus_terminal;
use crate::session::{format_relative_time, format_tool_display, truncate_prompt, GroupedSessions, Session, Status};
use crate::watcher::SessionWatcher;
use anyhow::Result;
use chrono::Utc;
use crossterm::{
    event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers},
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
    ExecutableCommand,
};
use ratatui::{
    prelude::*,
    widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Wrap},
};
use std::fs;
use std::io::stdout;
use std::path::PathBuf;
use std::time::Duration;

/// View mode for the TUI
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ViewMode {
    /// List view showing all sessions
    List,
    /// Detail view showing full info for selected session
    Detail,
}

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
    /// Demo mode - skip session liveness checks
    demo_mode: bool,
    /// Current view mode (list or detail)
    view_mode: ViewMode,
    /// Vertical scroll offset for detail view
    detail_scroll: u16,
    /// File watcher for instant session updates
    watcher: Option<SessionWatcher>,
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
            demo_mode: false,
            view_mode: ViewMode::List,
            detail_scroll: 0,
            watcher: SessionWatcher::new().ok(),
        }
    }

    /// Enable demo mode (skip session liveness checks).
    pub fn with_demo_mode(mut self, demo_mode: bool) -> Self {
        self.demo_mode = demo_mode;
        self
    }

    /// Load sessions from ~/.cctop/sessions/
    /// If `check_liveness` is true, validates each session is still alive (slow).
    pub fn load_sessions_with_liveness(&mut self, check_liveness: bool) {
        let skip_check = self.demo_mode || !check_liveness;
        self.sessions = load_all_sessions(skip_check).unwrap_or_default();
        self.sort_sessions();
        self.clamp_selection();
    }

    /// Sort sessions by status priority, then by last_activity.
    fn sort_sessions(&mut self) {
        self.sessions.sort_by(|a, b| {
            let priority = |s: &Status| match s {
                Status::WaitingPermission => 0,
                Status::WaitingInput | Status::NeedsAttention => 1,
                Status::Working => 2,
                Status::Idle => 3,
            };
            priority(&a.status)
                .cmp(&priority(&b.status))
                .then_with(|| b.last_activity.cmp(&a.last_activity))
        });
    }

    /// Ensure the selected index stays within bounds after sessions change.
    fn clamp_selection(&mut self) {
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
        use std::time::Instant;

        // Cleanup old session files (timestamp-based, fast)
        let _ = cleanup_stale_sessions(chrono::Duration::hours(24));

        // Initial load WITHOUT liveness check for fast startup
        self.load_sessions_with_liveness(false);

        // Track liveness check time (watcher handles instant change detection)
        let mut last_liveness_check = Instant::now();
        // Liveness check runs less frequently (every 30 seconds) since it's slow
        let liveness_interval = Duration::from_secs(30);

        while !self.should_quit {
            // Draw the UI
            terminal.draw(|frame| self.draw(frame))?;

            // Poll for events with short timeout for responsiveness
            if event::poll(Duration::from_millis(50))? {
                if let Event::Key(key) = event::read()? {
                    if key.kind == KeyEventKind::Press && self.handle_key(key) {
                        break;
                    }
                }
            }

            // Check file watcher for instant session updates
            if let Some(ref mut watcher) = self.watcher {
                if let Some(new_sessions) = watcher.poll_changes() {
                    self.sessions = new_sessions;
                    self.sort_sessions();
                    self.clamp_selection();
                }
            }

            // Periodically check liveness to clean up dead sessions (slow, runs infrequently)
            if last_liveness_check.elapsed() >= liveness_interval {
                self.load_sessions_with_liveness(true);
                last_liveness_check = Instant::now();
            }
        }

        Ok(())
    }

    /// Render the UI to the frame.
    pub fn draw(&self, frame: &mut Frame) {
        let area = frame.area();

        // Layout: header, content, footer
        let main_chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3), // header
                Constraint::Min(5),    // content
                Constraint::Length(1), // footer
            ])
            .split(area);

        self.render_header(frame, main_chunks[0]);

        // Render content based on view mode
        match self.view_mode {
            ViewMode::List => self.render_sessions(frame, main_chunks[1]),
            ViewMode::Detail => self.render_detail_view(frame, main_chunks[1]),
        }

        self.render_footer(frame, main_chunks[2]);
    }

    /// Handle a key event. Returns true if the app should quit.
    pub fn handle_key(&mut self, key: KeyEvent) -> bool {
        // Handle quit keys
        let is_quit_key = match key.code {
            KeyCode::Char('q') | KeyCode::Esc => true,
            KeyCode::Char('c' | 'd') if key.modifiers.contains(KeyModifiers::CONTROL) => true,
            _ => false,
        };

        if is_quit_key {
            self.should_quit = true;
            return true;
        }

        match key.code {
            KeyCode::Char('r') => {
                self.load_sessions_with_liveness(false);
            }
            KeyCode::Up | KeyCode::Char('k') => {
                self.handle_up();
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.handle_down();
            }
            KeyCode::Right | KeyCode::Char('l') => {
                self.enter_detail_view();
            }
            KeyCode::Left | KeyCode::Char('h') => {
                self.exit_detail_view();
            }
            KeyCode::Enter => {
                self.focus_selected();
            }
            _ => {}
        }
        false
    }

    /// Handle up key based on current view mode.
    fn handle_up(&mut self) {
        match self.view_mode {
            ViewMode::List => self.select_previous(),
            ViewMode::Detail => self.scroll_detail_up(),
        }
    }

    /// Handle down key based on current view mode.
    fn handle_down(&mut self) {
        match self.view_mode {
            ViewMode::List => self.select_next(),
            ViewMode::Detail => self.scroll_detail_down(),
        }
    }

    /// Enter detail view if there are sessions.
    fn enter_detail_view(&mut self) {
        if self.view_mode == ViewMode::List && !self.sessions.is_empty() {
            self.view_mode = ViewMode::Detail;
            self.detail_scroll = 0;
        }
    }

    /// Exit detail view and return to list.
    fn exit_detail_view(&mut self) {
        if self.view_mode == ViewMode::Detail {
            self.view_mode = ViewMode::List;
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

    /// Scroll detail view up by one line.
    fn scroll_detail_up(&mut self) {
        self.detail_scroll = self.detail_scroll.saturating_sub(1);
    }

    /// Scroll detail view down by one line.
    fn scroll_detail_down(&mut self) {
        self.detail_scroll = self.detail_scroll.saturating_add(1);
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
                Paragraph::new("No active sessions\n\nInstall the cctop plugin to get started:\n  claude plugin install cctop\n\nThen restart your Claude Code sessions.")
                    .style(Style::default().fg(Color::DarkGray))
                    .alignment(Alignment::Center);
            frame.render_widget(msg, area);
            return;
        }

        // Group sessions by status
        let grouped = GroupedSessions::from_sessions(&self.sessions);
        let (waiting_permission, waiting_input, working, idle) = grouped.as_tuple();

        // Build list items with section headers
        let mut items: Vec<ListItem> = Vec::new();

        // Helper to add a section
        let mut add_section = |title: &str, sessions: Vec<&Session>, color: Color| {
            if sessions.is_empty() {
                return;
            }

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
                let item = self.session_to_list_item(session, area.width, color);
                items.push(item);
            }

            // Add blank line after section
            items.push(ListItem::new(""));
        };

        add_section(
            "WAITING FOR PERMISSION",
            waiting_permission,
            Color::Rgb(239, 68, 68),
        );
        add_section(
            "WAITING FOR INPUT",
            waiting_input,
            Color::Rgb(245, 158, 11),
        );
        add_section("WORKING", working, Color::Rgb(34, 197, 94));
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

        let grouped = GroupedSessions::from_sessions(&self.sessions);
        let sections = [
            grouped.waiting_permission,
            grouped.waiting_input,
            grouped.working,
            grouped.idle,
        ];

        let mut offset = 0;
        let mut session_count = 0;

        for (i, section) in sections.iter().enumerate() {
            if section.is_empty() {
                continue;
            }

            offset += 1; // section header
            if self.selected_index < session_count + section.len() {
                return offset + (self.selected_index - session_count);
            }
            session_count += section.len();

            // Add sessions + blank line (except for last section which doesn't need trailing offset)
            let is_last = i == sections.len() - 1;
            if !is_last {
                offset += section.len() + 1;
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
    ) -> ListItem<'static> {
        let indicator = session.status.indicator();
        let time = format_relative_time(session.last_activity);

        // Show [compacted] indicator after branch if context was compacted
        let branch_display = if session.context_compacted {
            format!("{} [compacted]", session.branch)
        } else {
            session.branch.clone()
        };

        // Format: indicator project_name branch time
        let main_line = format!(
            "  {} {:<20} {:<15} {}",
            indicator, session.project_name, branch_display, time
        );

        let max_width = (width as usize).saturating_sub(8);
        let context_line = self.context_line_for_session(session, max_width.min(60));

        let content = if context_line.is_empty() {
            main_line
        } else {
            format!("{}\n    {}", main_line, context_line)
        };

        ListItem::new(content).style(Style::default().fg(color))
    }

    /// Get the context line for a session in the TUI list view.
    fn context_line_for_session(&self, session: &Session, max_width: usize) -> String {
        match session.status {
            Status::Idle => String::new(),
            Status::WaitingPermission => {
                if let Some(ref msg) = session.notification_message {
                    truncate_prompt(msg, max_width)
                } else {
                    "Permission needed".to_string()
                }
            }
            Status::WaitingInput | Status::NeedsAttention => {
                if let Some(ref prompt) = session.last_prompt {
                    format!("\"{}\"", truncate_prompt(prompt, max_width.saturating_sub(2)))
                } else {
                    String::new()
                }
            }
            Status::Working => {
                // Prefer tool display, fall back to prompt
                if let Some(ref tool) = session.last_tool {
                    format_tool_display(
                        tool,
                        session.last_tool_detail.as_deref(),
                        max_width,
                    )
                } else if let Some(ref prompt) = session.last_prompt {
                    format!("\"{}\"", truncate_prompt(prompt, max_width.saturating_sub(2)))
                } else {
                    String::new()
                }
            }
        }
    }

    /// Render the full-screen detail view for the selected session.
    fn render_detail_view(&self, frame: &mut Frame, area: Rect) {
        let Some(session) = self.sessions.get(self.selected_index) else {
            return;
        };

        let started = format_relative_time(session.started_at);
        let active = format_relative_time(session.last_activity);

        let terminal_session_id = session
            .terminal
            .session_id
            .as_ref()
            .map(|id| format!("\n  ID: {}", id))
            .unwrap_or_default();

        let terminal_info = format!(
            "{}\n  TTY: {}{}",
            session.terminal.program,
            session.terminal.tty.as_deref().unwrap_or("unknown"),
            terminal_session_id
        );

        let prompt_text = session.last_prompt.as_deref().unwrap_or("(no prompt)");

        // Build status line with compacted indicator
        let status_line = if session.context_compacted {
            format!("{}  [context compacted]", session.status.as_str())
        } else {
            session.status.as_str().to_string()
        };

        // Build tool info section if available
        let tool_section = if let Some(ref tool) = session.last_tool {
            let detail = session.last_tool_detail.as_deref().unwrap_or("");
            format!("\n\nTool:    {} {}", tool, detail)
        } else {
            String::new()
        };

        // Build notification section if available
        let notification_section = if let Some(ref msg) = session.notification_message {
            format!("\n\nNotification:\n  {}", msg)
        } else {
            String::new()
        };

        let details_text = format!(
            "Project:\n  {}\n\n\
             Branch:  {}\n\
             Status:  {}{}{}\n\n\
             Started: {}\n\
             Active:  {}\n\n\
             Terminal:\n  {}\n\n\
             Prompt:\n\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n{}",
            session.project_path,
            session.branch,
            status_line,
            tool_section,
            notification_section,
            started,
            active,
            terminal_info,
            prompt_text
        );

        let details = Paragraph::new(details_text)
            .block(
                Block::default()
                    .title(format!(" {} ", session.project_name))
                    .borders(Borders::ALL)
                    .border_style(Style::default().fg(Color::DarkGray)),
            )
            .wrap(Wrap { trim: false })
            .scroll((self.detail_scroll, 0));

        frame.render_widget(details, area);
    }

    /// Render the footer with keyboard shortcuts.
    fn render_footer(&self, frame: &mut Frame, area: Rect) {
        let footer_text = match self.view_mode {
            ViewMode::List => {
                "  \u{2191}/\u{2193}: nav   \u{2192}: details   enter: jump   r: refresh   q: quit"
            }
            ViewMode::Detail => {
                "  \u{2191}/\u{2193}: scroll   \u{2190}: back   enter: jump   q: quit"
            }
        };
        let footer = Paragraph::new(footer_text).style(Style::default().fg(Color::DarkGray));
        frame.render_widget(footer, area);
    }
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

/// Check if a session is still alive by checking if its PID is running.
///
/// If the session has a PID, uses `is_pid_alive` for a fast check.
/// Falls back to the slower ps+lsof check for sessions without PID (backwards compatibility).
fn is_session_alive(session: &Session) -> bool {
    use crate::session::is_pid_alive;

    // If session has a PID, use the fast PID check
    if let Some(pid) = session.pid {
        return is_pid_alive(pid);
    }

    // Fallback for old sessions without PID: use the slow ps+lsof approach
    is_session_alive_by_path(&session.project_path)
}

/// Fallback liveness check for sessions without PID.
/// Uses `ps` and `lsof` to check if any claude process has the session's project_path as cwd.
fn is_session_alive_by_path(project_path: &str) -> bool {
    use std::process::Command;

    let output = Command::new("sh")
        .arg("-c")
        .arg(format!(
            "ps aux | grep -E 'claude|Claude' | grep -v grep | awk '{{print $2}}' | while read pid; do lsof -p $pid 2>/dev/null | grep cwd | grep -q '{}' && echo found; done",
            project_path
        ))
        .output();

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            stdout.contains("found")
        }
        Err(_) => {
            // If the check fails, assume session is alive to avoid false deletions
            true
        }
    }
}

/// Load all sessions from ~/.cctop/sessions/
///
/// Also validates sessions and removes stale ones whose Claude Code process has ended.
/// If `skip_liveness_check` is true (demo mode), sessions are loaded without validation.
fn load_all_sessions(skip_liveness_check: bool) -> Result<Vec<Session>> {
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
                Ok(session) => {
                    // In demo mode, skip liveness check
                    if skip_liveness_check || is_session_alive(&session) {
                        sessions.push(session);
                    } else {
                        // Session has ended, remove the stale file
                        let _ = fs::remove_file(&path);
                    }
                }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::TerminalInfo;
    use chrono::Utc;

    fn make_test_session(id: &str, status: Status, project: &str) -> Session {
        Session {
            session_id: id.to_string(),
            project_path: format!("/nonexistent/test/projects/{}", project),
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
            pid: None,
            last_tool: None,
            last_tool_detail: None,
            notification_message: None,
            context_compacted: false,
        }
    }

    #[test]
    fn test_grouped_sessions() {
        let sessions = vec![
            make_test_session("1", Status::Idle, "proj1"),
            make_test_session("2", Status::Working, "proj2"),
            make_test_session("3", Status::WaitingInput, "proj3"),
            make_test_session("4", Status::Idle, "proj4"),
            make_test_session("5", Status::WaitingPermission, "proj5"),
        ];

        let grouped = GroupedSessions::from_sessions(&sessions);

        assert_eq!(grouped.waiting_permission.len(), 1);
        assert_eq!(grouped.waiting_input.len(), 1);
        assert_eq!(grouped.working.len(), 1);
        assert_eq!(grouped.idle.len(), 2);

        assert_eq!(grouped.waiting_permission[0].session_id, "5");
        assert_eq!(grouped.waiting_input[0].session_id, "3");
        assert_eq!(grouped.working[0].session_id, "2");
    }

    #[test]
    fn test_app_new() {
        let config = Config::default();
        let app = App::new(config);

        assert!(app.sessions.is_empty());
        assert_eq!(app.selected_index, 0);
        assert!(!app.should_quit);
        assert_eq!(app.view_mode, ViewMode::List);
        assert_eq!(app.detail_scroll, 0);
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
    fn test_handle_key_ctrl_c_quit() {
        let config = Config::default();
        let mut app = App::new(config);

        let key = KeyEvent::new(KeyCode::Char('c'), crossterm::event::KeyModifiers::CONTROL);
        let should_quit = app.handle_key(key);

        assert!(should_quit);
        assert!(app.should_quit);
    }

    #[test]
    fn test_handle_key_ctrl_d_quit() {
        let config = Config::default();
        let mut app = App::new(config);

        let key = KeyEvent::new(KeyCode::Char('d'), crossterm::event::KeyModifiers::CONTROL);
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
    fn test_handle_key_right_arrow_enters_detail_view() {
        let config = Config::default();
        let mut app = App::new(config);
        app.sessions = vec![make_test_session("1", Status::Idle, "proj1")];

        assert_eq!(app.view_mode, ViewMode::List);

        let key = KeyEvent::new(KeyCode::Right, crossterm::event::KeyModifiers::NONE);
        let should_quit = app.handle_key(key);

        assert!(!should_quit);
        assert_eq!(app.view_mode, ViewMode::Detail);
        assert_eq!(app.detail_scroll, 0);
    }

    #[test]
    fn test_handle_key_right_arrow_no_effect_when_empty() {
        let config = Config::default();
        let mut app = App::new(config);
        // No sessions

        let key = KeyEvent::new(KeyCode::Right, crossterm::event::KeyModifiers::NONE);
        app.handle_key(key);

        assert_eq!(app.view_mode, ViewMode::List);
    }

    #[test]
    fn test_handle_key_left_arrow_returns_to_list() {
        let config = Config::default();
        let mut app = App::new(config);
        app.sessions = vec![make_test_session("1", Status::Idle, "proj1")];
        app.view_mode = ViewMode::Detail;

        let key = KeyEvent::new(KeyCode::Left, crossterm::event::KeyModifiers::NONE);
        app.handle_key(key);

        assert_eq!(app.view_mode, ViewMode::List);
    }

    #[test]
    fn test_detail_view_up_down_scrolls() {
        let config = Config::default();
        let mut app = App::new(config);
        app.sessions = vec![make_test_session("1", Status::Idle, "proj1")];
        app.view_mode = ViewMode::Detail;
        app.detail_scroll = 5;

        // Down scrolls down
        let key = KeyEvent::new(KeyCode::Down, crossterm::event::KeyModifiers::NONE);
        app.handle_key(key);
        assert_eq!(app.detail_scroll, 6);

        // Up scrolls up
        let key = KeyEvent::new(KeyCode::Up, crossterm::event::KeyModifiers::NONE);
        app.handle_key(key);
        assert_eq!(app.detail_scroll, 5);
    }

    #[test]
    fn test_detail_view_scroll_up_saturates_at_zero() {
        let config = Config::default();
        let mut app = App::new(config);
        app.sessions = vec![make_test_session("1", Status::Idle, "proj1")];
        app.view_mode = ViewMode::Detail;
        app.detail_scroll = 0;

        let key = KeyEvent::new(KeyCode::Up, crossterm::event::KeyModifiers::NONE);
        app.handle_key(key);

        assert_eq!(app.detail_scroll, 0); // Stays at 0, doesn't underflow
    }

    #[test]
    fn test_list_view_up_down_navigates() {
        let config = Config::default();
        let mut app = App::new(config);
        app.sessions = vec![
            make_test_session("1", Status::Idle, "proj1"),
            make_test_session("2", Status::Idle, "proj2"),
        ];
        app.view_mode = ViewMode::List;
        app.selected_index = 0;

        let key = KeyEvent::new(KeyCode::Down, crossterm::event::KeyModifiers::NONE);
        app.handle_key(key);

        assert_eq!(app.selected_index, 1);
        assert_eq!(app.view_mode, ViewMode::List);
    }

    // Note: test_enter_works_in_detail_view was removed because it triggers real
    // subprocess spawning (code --goto) which causes VS Code to open files during tests.
    // The focus functionality cannot be properly unit tested without mocking.

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
        // Test newline normalization
        assert_eq!(truncate_prompt("hello\nworld", 50), "hello world");
        assert_eq!(truncate_prompt("line1\n\nline2\nline3", 50), "line1 line2 line3");
        // Test combined truncation and normalization
        assert_eq!(truncate_prompt("hello\nworld", 10), "hello w...");
    }

    #[test]
    fn test_context_line_idle_is_empty() {
        let config = Config::default();
        let app = App::new(config);
        let session = make_test_session("1", Status::Idle, "proj1");
        assert_eq!(app.context_line_for_session(&session, 60), "");
    }

    #[test]
    fn test_context_line_working_with_tool() {
        let config = Config::default();
        let app = App::new(config);
        let mut session = make_test_session("1", Status::Working, "proj1");
        session.last_tool = Some("Bash".to_string());
        session.last_tool_detail = Some("npm test".to_string());
        let line = app.context_line_for_session(&session, 60);
        assert_eq!(line, "Running: npm test");
    }

    #[test]
    fn test_context_line_working_falls_back_to_prompt() {
        let config = Config::default();
        let app = App::new(config);
        let session = make_test_session("1", Status::Working, "proj1");
        let line = app.context_line_for_session(&session, 60);
        assert!(line.starts_with('"'));
        assert!(line.ends_with('"'));
    }

    #[test]
    fn test_context_line_waiting_permission() {
        let config = Config::default();
        let app = App::new(config);
        let session = make_test_session("1", Status::WaitingPermission, "proj1");
        let line = app.context_line_for_session(&session, 60);
        assert_eq!(line, "Permission needed");
    }

    #[test]
    fn test_context_line_waiting_permission_with_message() {
        let config = Config::default();
        let app = App::new(config);
        let mut session = make_test_session("1", Status::WaitingPermission, "proj1");
        session.notification_message = Some("Allow Bash: rm -rf /tmp/test".to_string());
        let line = app.context_line_for_session(&session, 60);
        assert_eq!(line, "Allow Bash: rm -rf /tmp/test");
    }

    #[test]
    fn test_context_line_waiting_input() {
        let config = Config::default();
        let app = App::new(config);
        let session = make_test_session("1", Status::WaitingInput, "proj1");
        let line = app.context_line_for_session(&session, 60);
        assert!(line.starts_with('"'));
        assert!(line.ends_with('"'));
    }

    #[test]
    fn test_sort_sessions_priority() {
        let config = Config::default();
        let mut app = App::new(config);
        app.sessions = vec![
            make_test_session("idle", Status::Idle, "proj1"),
            make_test_session("working", Status::Working, "proj2"),
            make_test_session("perm", Status::WaitingPermission, "proj3"),
            make_test_session("input", Status::WaitingInput, "proj4"),
        ];
        app.sort_sessions();

        assert_eq!(app.sessions[0].session_id, "perm");        // priority 0
        assert_eq!(app.sessions[1].session_id, "input");        // priority 1
        assert_eq!(app.sessions[2].session_id, "working");      // priority 2
        assert_eq!(app.sessions[3].session_id, "idle");         // priority 3
    }

    #[test]
    fn test_calculate_actual_list_index_four_sections() {
        let config = Config::default();
        let mut app = App::new(config);
        app.sessions = vec![
            make_test_session("perm", Status::WaitingPermission, "proj1"),
            make_test_session("input", Status::WaitingInput, "proj2"),
            make_test_session("working", Status::Working, "proj3"),
            make_test_session("idle", Status::Idle, "proj4"),
        ];
        app.sort_sessions();

        // First session (WaitingPermission): header(0) + session(1) => index 1
        app.selected_index = 0;
        assert_eq!(app.calculate_actual_list_index(), 1);

        // Second session (WaitingInput): header(0) + session(1) + blank(2) + header(3) + session(4) => index 4
        app.selected_index = 1;
        assert_eq!(app.calculate_actual_list_index(), 4);
    }
}
