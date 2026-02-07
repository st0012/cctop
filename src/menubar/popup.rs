//! egui popup rendering for the cctop menubar.
//!
//! Renders the session list popup with status dots, hover effects, and proper styling.
//! Features an arrow pointing to the tray icon and rounded corners.

use crate::session::{format_relative_time, format_tool_display, truncate_prompt, GroupedSessions, Session, Status};
use egui::{Color32, ScrollArea, epaint::PathShape, Frame, Margin, Pos2, Rect, RichText, Rounding, Sense, Shape, Stroke, Vec2};

/// Special return value indicating the user clicked "Quit".
pub const QUIT_ACTION: &str = "__quit__";

/// Content dimensions.
pub const CONTENT_WIDTH: f32 = 288.0;
/// Row height for sessions with a context line (prompt/tool info).
pub const ROW_HEIGHT_WITH_CONTEXT: f32 = 62.0;
/// Row height for sessions without context (idle).
pub const ROW_HEIGHT_MINIMAL: f32 = 44.0;
pub const HEADER_HEIGHT: f32 = 28.0;
pub const QUIT_ROW_HEIGHT: f32 = 36.0;

/// Arrow dimensions (pointing up to tray icon).
pub const ARROW_HEIGHT: f32 = 12.0;
pub const ARROW_WIDTH: f32 = 16.0;

/// Border radius for rounded corners.
pub const BORDER_RADIUS: f32 = 7.0;

/// Padding around the content for rounded corners to be visible.
pub const WINDOW_PADDING: f32 = 1.0;

/// Total popup width including padding.
pub const POPUP_WIDTH: f32 = CONTENT_WIDTH + (WINDOW_PADDING * 2.0);

/// Maximum height for the scrollable session content area.
const MAX_SCROLL_HEIGHT: f32 = 440.0;

/// Colors matching the reference design.
pub mod colors {
    use egui::Color32;

    /// Background color: #2f2f2f (47, 47, 47)
    pub fn background() -> Color32 {
        Color32::from_rgb(47, 47, 47)
    }
    /// Hover color: rgba(255, 255, 255, 0.1)
    pub fn hover() -> Color32 {
        Color32::from_rgba_unmultiplied(255, 255, 255, 26)
    }
    /// Primary text color: white
    pub const TEXT_PRIMARY: Color32 = Color32::WHITE;
    /// Secondary text color: rgb(156, 163, 175)
    pub const TEXT_SECONDARY: Color32 = Color32::from_rgb(156, 163, 175);
    /// Dimmer text for context lines: slightly less visible than secondary
    pub const TEXT_DIM: Color32 = Color32::from_rgb(120, 127, 139);
    /// Status red: rgb(239, 68, 68) - Waiting Permission
    pub const STATUS_RED: Color32 = Color32::from_rgb(239, 68, 68);
    /// Status amber: rgb(245, 158, 11) - Waiting Input / Needs Attention
    pub const STATUS_AMBER: Color32 = Color32::from_rgb(245, 158, 11);
    /// Status green: rgb(34, 197, 94) - Working
    pub const STATUS_GREEN: Color32 = Color32::from_rgb(34, 197, 94);
    /// Status gray: rgb(156, 163, 175) - Idle
    pub const STATUS_GRAY: Color32 = Color32::from_rgb(156, 163, 175);
    /// Separator color
    pub fn separator() -> Color32 {
        Color32::from_rgba_unmultiplied(255, 255, 255, 20)
    }
}

/// Get the status dot color for a session status.
fn status_color(status: &Status) -> Color32 {
    match status {
        Status::WaitingPermission => colors::STATUS_RED,
        Status::WaitingInput | Status::NeedsAttention => colors::STATUS_AMBER,
        Status::Working => colors::STATUS_GREEN,
        Status::Idle => colors::STATUS_GRAY,
    }
}

/// Get the optional background tint for attention rows.
/// Currently disabled - the colored dots and section headers already convey status.
fn row_bg_tint(_status: &Status) -> Option<Color32> {
    None
}

/// Compute pulsing opacity for attention dots (1-2s cycle, 60-100% opacity).
fn pulsing_alpha(ctx: &egui::Context) -> f32 {
    let time = ctx.input(|i| i.time);
    // Sine wave: 1.5s period, oscillating between 0.6 and 1.0
    let t = (time * std::f64::consts::TAU / 1.5).sin() as f32;
    0.8 + 0.2 * t // range [0.6, 1.0]
}

/// Get the row height for a session based on whether it has context to display.
fn row_height_for_session(session: &Session) -> f32 {
    if session.status == Status::Idle {
        ROW_HEIGHT_MINIMAL
    } else if context_line(session).is_some() {
        ROW_HEIGHT_WITH_CONTEXT
    } else {
        ROW_HEIGHT_MINIMAL
    }
}

/// Get the context line text for a session (3rd line in the row).
/// Returns None for idle sessions or sessions with no context.
fn context_line(session: &Session) -> Option<String> {
    match session.status {
        Status::Idle => None,
        Status::WaitingPermission => {
            if let Some(ref msg) = session.notification_message {
                Some(truncate_prompt(msg, 38))
            } else {
                Some("Permission needed".to_string())
            }
        }
        Status::WaitingInput | Status::NeedsAttention => {
            session.last_prompt.as_ref().map(|p| {
                format!("\"{}\"", truncate_prompt(p, 36))
            })
        }
        Status::Working => {
            // Prefer tool display, fall back to prompt
            if let Some(ref tool) = session.last_tool {
                if let Some(ref detail) = session.last_tool_detail {
                    Some(format_tool_display(tool, Some(detail), 38))
                } else {
                    Some(format_tool_display(tool, None, 38))
                }
            } else {
                session.last_prompt.as_ref().map(|p| {
                    format!("\"{}\"", truncate_prompt(p, 36))
                })
            }
        }
    }
}

/// Draw the arrow pointing up to the tray icon.
fn draw_arrow(painter: &egui::Painter, center_x: f32, top_y: f32) {
    let points = vec![
        Pos2::new(center_x, top_y),                              // Top point
        Pos2::new(center_x - ARROW_WIDTH / 2.0, top_y + ARROW_HEIGHT), // Bottom left
        Pos2::new(center_x + ARROW_WIDTH / 2.0, top_y + ARROW_HEIGHT), // Bottom right
    ];

    let shape = Shape::Path(PathShape::convex_polygon(
        points,
        colors::background(),
        Stroke::NONE,
    ));
    painter.add(shape);
}

/// Render the popup and return the clicked session ID (or QUIT_ACTION).
///
/// Returns `Some(session_id)` if a session was clicked,
/// `Some(QUIT_ACTION)` if quit was clicked,
/// or `None` if nothing was clicked.
pub fn render_popup(ctx: &egui::Context, sessions: &[Session]) -> Option<String> {
    let mut clicked_id: Option<String> = None;
    let grouped = GroupedSessions::from_sessions(sessions);
    let screen_rect = ctx.screen_rect();
    let painter = ctx.layer_painter(egui::LayerId::background());

    // Draw arrow at top center
    let arrow_center_x = screen_rect.center().x;
    draw_arrow(&painter, arrow_center_x, 0.0);

    // Draw rounded content area below arrow (inset by WINDOW_PADDING)
    let content_rect = Rect::from_min_max(
        Pos2::new(WINDOW_PADDING, ARROW_HEIGHT),
        Pos2::new(screen_rect.max.x - WINDOW_PADDING, screen_rect.max.y - WINDOW_PADDING),
    );
    painter.rect_filled(content_rect, Rounding::same(BORDER_RADIUS), colors::background());

    egui::Area::new(egui::Id::new("cctop_popup"))
        .fixed_pos(Pos2::new(WINDOW_PADDING, ARROW_HEIGHT))
        .show(ctx, |ui| {
            Frame::none()
                .inner_margin(Margin::symmetric(0.0, FRAME_VERTICAL_PADDING))
                .show(ui, |ui| {
                    ui.set_width(CONTENT_WIDTH);

                    // Scrollable session area
                    let sessions_content_height = sessions_total_height(sessions);
                    let needs_scroll = sessions_content_height > MAX_SCROLL_HEIGHT;
                    let scroll_height = if needs_scroll { MAX_SCROLL_HEIGHT } else { sessions_content_height };

                    ScrollArea::vertical()
                        .max_height(scroll_height)
                        .auto_shrink([false, true])
                        .show(ui, |ui| {
                            ui.set_width(CONTENT_WIDTH);

                            // Compute pulsing alpha once for all attention dots
                            let has_attention = !grouped.waiting_permission.is_empty()
                                || !grouped.waiting_input.is_empty();
                            let pulse_alpha = if has_attention {
                                Some(pulsing_alpha(ui.ctx()))
                            } else {
                                None
                            };

                            // Render each section (4-group model)
                            if let Some(id) = render_section(ui, "WAITING FOR PERMISSION", &grouped.waiting_permission, Some(colors::STATUS_RED), pulse_alpha) {
                                clicked_id = Some(id);
                            }
                            if let Some(id) = render_section(ui, "WAITING FOR INPUT", &grouped.waiting_input, Some(colors::STATUS_AMBER), pulse_alpha) {
                                clicked_id = Some(id);
                            }
                            if let Some(id) = render_section(ui, "WORKING", &grouped.working, None, None) {
                                clicked_id = Some(id);
                            }
                            if let Some(id) = render_section(ui, "IDLE", &grouped.idle, None, None) {
                                clicked_id = Some(id);
                            }

                            // Request continuous repaints while attention sessions exist
                            if has_attention {
                                ui.ctx().request_repaint();
                            }

                            // No sessions message
                            if !grouped.has_any() {
                                ui.add_space(8.0);
                                ui.horizontal(|ui| {
                                    ui.add_space(16.0);
                                    ui.label(
                                        RichText::new("No active sessions")
                                            .color(colors::TEXT_SECONDARY)
                                            .size(13.0),
                                    );
                                });
                                ui.add_space(8.0);
                            }
                        });

                    // Separator (always visible, outside scroll area)
                    ui.add_space(4.0);
                    let separator_rect = Rect::from_min_size(ui.cursor().min, Vec2::new(CONTENT_WIDTH, 1.0));
                    ui.painter().rect_filled(separator_rect, 0.0, colors::separator());
                    ui.add_space(5.0);

                    // Quit row (always visible, outside scroll area)
                    if render_quit_row(ui) {
                        clicked_id = Some(QUIT_ACTION.to_string());
                    }
                });
        });

    clicked_id
}

/// Render a section with header and session rows.
/// Returns the clicked session ID if any row was clicked.
/// If `header_color` is provided, the header text uses that color instead of the default.
fn render_section(ui: &mut egui::Ui, header: &str, sessions: &[&Session], header_color: Option<Color32>, pulse_alpha: Option<f32>) -> Option<String> {
    if sessions.is_empty() {
        return None;
    }
    render_section_header(ui, header, header_color);
    for session in sessions {
        if render_session_row(ui, session, pulse_alpha) {
            return Some(session.session_id.clone());
        }
    }
    None
}

/// Render a section header (e.g., "NEEDS ATTENTION", "WORKING", "IDLE").
/// If `color` is provided, uses that color; otherwise uses the default secondary color.
fn render_section_header(ui: &mut egui::Ui, text: &str, color: Option<Color32>) {
    let header_color = color.unwrap_or(colors::TEXT_SECONDARY);
    ui.add_space(4.0);
    ui.horizontal(|ui| {
        ui.add_space(16.0);
        ui.label(
            RichText::new(text)
                .color(header_color)
                .size(10.0)
                .strong(),
        );
    });
    ui.add_space(2.0);
}

/// Render a session row with status dot, project name, branch, time, and optional context.
/// If `pulse_alpha` is provided, the status dot pulses for attention statuses.
/// Returns true if the row was clicked.
fn render_session_row(ui: &mut egui::Ui, session: &Session, pulse_alpha: Option<f32>) -> bool {
    let height = row_height_for_session(session);
    let row_rect = Rect::from_min_size(
        ui.cursor().min,
        Vec2::new(CONTENT_WIDTH, height),
    );

    // Handle interaction
    let response = ui.allocate_rect(row_rect, Sense::click());
    let is_hovered = response.hovered();

    // Draw background tint for attention rows
    if let Some(tint) = row_bg_tint(&session.status) {
        ui.painter().rect_filled(row_rect, 0.0, tint);
    }

    // Draw hover background (on top of tint)
    if is_hovered {
        ui.painter().rect_filled(row_rect, 0.0, colors::hover());
    }

    // Draw status dot (vertically centered relative to the first two lines)
    let dot_center = Pos2::new(row_rect.min.x + 24.0, row_rect.min.y + 16.0);
    let base_color = status_color(&session.status);
    // Apply pulsing alpha to attention dots
    let dot_color = if let Some(alpha) = pulse_alpha {
        let [r, g, b, _] = base_color.to_array();
        Color32::from_rgba_unmultiplied(r, g, b, (alpha * 255.0) as u8)
    } else {
        base_color
    };
    ui.painter().circle_filled(dot_center, 4.0, dot_color);

    let text_x = row_rect.min.x + 40.0;

    // Draw project name (line 1, left)
    ui.painter().text(
        Pos2::new(text_x, row_rect.min.y + 8.0),
        egui::Align2::LEFT_TOP,
        &session.project_name,
        egui::FontId::proportional(14.0),
        colors::TEXT_PRIMARY,
    );

    // Draw relative time (line 1, right-aligned)
    let time_text = format_relative_time(session.last_activity);
    ui.painter().text(
        Pos2::new(row_rect.max.x - 16.0, row_rect.min.y + 10.0),
        egui::Align2::RIGHT_TOP,
        &time_text,
        egui::FontId::proportional(11.0),
        colors::TEXT_SECONDARY,
    );

    // Draw branch name (line 2), with compacted indicator if context was compacted
    let branch_text = if session.context_compacted {
        format!("{} [compacted]", session.branch)
    } else {
        session.branch.clone()
    };
    ui.painter().text(
        Pos2::new(text_x, row_rect.min.y + 24.0),
        egui::Align2::LEFT_TOP,
        &branch_text,
        egui::FontId::proportional(11.0),
        colors::TEXT_SECONDARY,
    );

    // Draw context line (line 3) if applicable
    if let Some(context) = context_line(session) {
        ui.painter().text(
            Pos2::new(text_x, row_rect.min.y + 40.0),
            egui::Align2::LEFT_TOP,
            &context,
            egui::FontId::proportional(10.0),
            colors::TEXT_DIM,
        );
    }

    response.clicked()
}

/// Render the "Quit cctop" row.
/// Returns true if clicked.
fn render_quit_row(ui: &mut egui::Ui) -> bool {
    let row_rect = Rect::from_min_size(
        ui.cursor().min,
        Vec2::new(CONTENT_WIDTH, QUIT_ROW_HEIGHT),
    );

    // Handle interaction
    let response = ui.allocate_rect(row_rect, Sense::click());
    let is_hovered = response.hovered();

    // Draw hover background
    if is_hovered {
        ui.painter().rect_filled(row_rect, 0.0, colors::hover());
    }

    // Draw "Quit cctop" text
    ui.painter().text(
        Pos2::new(row_rect.min.x + 16.0, row_rect.center().y),
        egui::Align2::LEFT_CENTER,
        "Quit cctop",
        egui::FontId::proportional(13.0),
        colors::TEXT_PRIMARY,
    );

    response.clicked()
}

/// Vertical padding from Frame's inner_margin.
const FRAME_VERTICAL_PADDING: f32 = 8.0;

/// Calculate section height (header + variable-height rows).
fn section_height_for_sessions(sessions: &[&Session]) -> f32 {
    if sessions.is_empty() {
        0.0
    } else {
        let rows_height: f32 = sessions.iter().map(|s| row_height_for_session(s)).sum();
        HEADER_HEIGHT + rows_height
    }
}

/// Calculate the total height of all session content (sections only, no chrome).
fn sessions_total_height(sessions: &[Session]) -> f32 {
    let grouped = GroupedSessions::from_sessions(sessions);

    let content_height = section_height_for_sessions(&grouped.waiting_permission)
        + section_height_for_sessions(&grouped.waiting_input)
        + section_height_for_sessions(&grouped.working)
        + section_height_for_sessions(&grouped.idle);

    if content_height == 0.0 {
        ROW_HEIGHT_MINIMAL // "No active sessions" message
    } else {
        content_height
    }
}

/// Calculate the required popup height based on sessions.
/// This must match exactly what render_popup draws.
pub fn calculate_popup_height(sessions: &[Session]) -> f32 {
    let sessions_height = sessions_total_height(sessions);
    let capped_height = sessions_height.min(MAX_SCROLL_HEIGHT);

    // Arrow + sessions (capped) + separator (4.0 + 1.0 + 5.0) + quit row + frame padding + bottom window padding
    ARROW_HEIGHT + capped_height + 10.0 + QUIT_ROW_HEIGHT + (FRAME_VERTICAL_PADDING * 2.0) + WINDOW_PADDING
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
            last_tool: None,
            last_tool_detail: None,
            notification_message: None,
            context_compacted: false,
        }
    }

    fn make_test_session_no_prompt(id: &str, status: Status, project: &str, branch: &str) -> Session {
        let mut s = make_test_session(id, status, project, branch);
        s.last_prompt = None;
        s
    }

    #[test]
    fn test_grouped_sessions() {
        let sessions = vec![
            make_test_session("1", Status::Idle, "proj1", "main"),
            make_test_session("2", Status::Working, "proj2", "feature"),
            make_test_session("3", Status::WaitingInput, "proj3", "fix"),
            make_test_session("4", Status::Idle, "proj4", "develop"),
            make_test_session("5", Status::WaitingPermission, "proj5", "hotfix"),
        ];

        let grouped = GroupedSessions::from_sessions(&sessions);

        assert_eq!(grouped.waiting_permission.len(), 1);
        assert_eq!(grouped.waiting_input.len(), 1);
        assert_eq!(grouped.working.len(), 1);
        assert_eq!(grouped.idle.len(), 2);
        assert!(grouped.has_any());
    }

    #[test]
    fn test_grouped_sessions_empty() {
        let sessions: Vec<Session> = vec![];
        let grouped = GroupedSessions::from_sessions(&sessions);
        assert!(!grouped.has_any());
    }

    #[test]
    fn test_status_color() {
        assert_eq!(
            status_color(&Status::WaitingPermission),
            colors::STATUS_RED
        );
        assert_eq!(status_color(&Status::WaitingInput), colors::STATUS_AMBER);
        assert_eq!(status_color(&Status::NeedsAttention), colors::STATUS_AMBER);
        assert_eq!(status_color(&Status::Working), colors::STATUS_GREEN);
        assert_eq!(status_color(&Status::Idle), colors::STATUS_GRAY);
    }

    #[test]
    fn test_row_height_idle_is_minimal() {
        let session = make_test_session("1", Status::Idle, "proj1", "main");
        assert_eq!(row_height_for_session(&session), ROW_HEIGHT_MINIMAL);
    }

    #[test]
    fn test_row_height_working_with_prompt_is_tall() {
        let session = make_test_session("1", Status::Working, "proj1", "main");
        assert_eq!(row_height_for_session(&session), ROW_HEIGHT_WITH_CONTEXT);
    }

    #[test]
    fn test_row_height_working_without_prompt_is_minimal() {
        let session = make_test_session_no_prompt("1", Status::Working, "proj1", "main");
        assert_eq!(row_height_for_session(&session), ROW_HEIGHT_MINIMAL);
    }

    #[test]
    fn test_row_height_needs_attention_with_prompt_is_tall() {
        let session = make_test_session("1", Status::WaitingInput, "proj1", "main");
        assert_eq!(row_height_for_session(&session), ROW_HEIGHT_WITH_CONTEXT);
    }

    #[test]
    fn test_row_height_waiting_permission_is_tall() {
        let session = make_test_session("1", Status::WaitingPermission, "proj1", "main");
        // WaitingPermission always shows context ("Permission needed")
        assert_eq!(row_height_for_session(&session), ROW_HEIGHT_WITH_CONTEXT);
    }

    #[test]
    fn test_context_line_idle_is_none() {
        let session = make_test_session("1", Status::Idle, "proj1", "main");
        assert!(context_line(&session).is_none());
    }

    #[test]
    fn test_context_line_working_with_prompt() {
        let session = make_test_session("1", Status::Working, "proj1", "main");
        let line = context_line(&session).unwrap();
        assert!(line.starts_with('"'));
        assert!(line.ends_with('"'));
    }

    #[test]
    fn test_context_line_no_prompt_is_none() {
        let session = make_test_session_no_prompt("1", Status::Working, "proj1", "main");
        assert!(context_line(&session).is_none());
    }

    #[test]
    fn test_calculate_popup_height_empty() {
        let sessions: Vec<Session> = vec![];
        let height = calculate_popup_height(&sessions);
        // Should have padding + no sessions row + separator + quit row
        assert!(height > 0.0);
    }

    #[test]
    fn test_calculate_popup_height_with_sessions() {
        let sessions = vec![
            make_test_session("1", Status::Idle, "proj1", "main"),
            make_test_session("2", Status::Working, "proj2", "feature"),
        ];
        let height = calculate_popup_height(&sessions);
        // Idle row (44) + Working row with prompt (62) + 2 headers (28 each) + chrome
        let expected_sessions = ROW_HEIGHT_MINIMAL + ROW_HEIGHT_WITH_CONTEXT + (2.0 * HEADER_HEIGHT);
        let expected_min = ARROW_HEIGHT + expected_sessions + 10.0 + QUIT_ROW_HEIGHT + (FRAME_VERTICAL_PADDING * 2.0) + WINDOW_PADDING;
        assert!((height - expected_min).abs() < 1.0);
    }

    #[test]
    fn test_calculate_popup_height_capped() {
        // Create many sessions to exceed MAX_SCROLL_HEIGHT
        let mut sessions = Vec::new();
        for i in 0..20 {
            sessions.push(make_test_session(&format!("{}", i), Status::Working, &format!("proj{}", i), "main"));
        }
        let height = calculate_popup_height(&sessions);
        let max_height = ARROW_HEIGHT + MAX_SCROLL_HEIGHT + 10.0 + QUIT_ROW_HEIGHT + (FRAME_VERTICAL_PADDING * 2.0) + WINDOW_PADDING;
        assert!(height <= max_height + 1.0, "Height {} should be capped at ~{}", height, max_height);
    }

    #[test]
    fn test_variable_height_mixed_sessions() {
        let sessions = vec![
            make_test_session("1", Status::Idle, "proj1", "main"),          // 44px
            make_test_session("2", Status::Working, "proj2", "feature"),    // 62px
            make_test_session_no_prompt("3", Status::Working, "proj3", "dev"), // 44px (no prompt)
        ];
        let total = sessions_total_height(&sessions);
        // 2 headers (idle + working) + 44 + 62 + 44
        let expected = (2.0 * HEADER_HEIGHT) + ROW_HEIGHT_MINIMAL + ROW_HEIGHT_WITH_CONTEXT + ROW_HEIGHT_MINIMAL;
        assert!((total - expected).abs() < 1.0);
    }

    #[test]
    fn test_context_line_waiting_permission_default() {
        let session = make_test_session("1", Status::WaitingPermission, "proj1", "main");
        let line = context_line(&session).unwrap();
        assert_eq!(line, "Permission needed");
    }

    #[test]
    fn test_context_line_waiting_permission_with_message() {
        let mut session = make_test_session("1", Status::WaitingPermission, "proj1", "main");
        session.notification_message = Some("Allow Bash: npm test".to_string());
        let line = context_line(&session).unwrap();
        assert_eq!(line, "Allow Bash: npm test");
    }

    #[test]
    fn test_context_line_waiting_input() {
        let session = make_test_session("1", Status::WaitingInput, "proj1", "main");
        let line = context_line(&session).unwrap();
        assert!(line.starts_with('"'));
        assert!(line.ends_with('"'));
    }

    #[test]
    fn test_context_line_working_with_tool() {
        let mut session = make_test_session("1", Status::Working, "proj1", "main");
        session.last_tool = Some("Bash".to_string());
        session.last_tool_detail = Some("npm test".to_string());
        let line = context_line(&session).unwrap();
        assert!(line.starts_with("Running: "));
    }

    #[test]
    fn test_context_line_working_with_edit_tool() {
        let mut session = make_test_session("1", Status::Working, "proj1", "main");
        session.last_tool = Some("Edit".to_string());
        session.last_tool_detail = Some("/src/main.rs".to_string());
        let line = context_line(&session).unwrap();
        assert!(line.starts_with("Editing "));
    }

    #[test]
    fn test_row_bg_tint_disabled() {
        // Background tints are disabled - dots and headers convey status
        assert!(row_bg_tint(&Status::WaitingPermission).is_none());
        assert!(row_bg_tint(&Status::WaitingInput).is_none());
        assert!(row_bg_tint(&Status::Working).is_none());
        assert!(row_bg_tint(&Status::Idle).is_none());
    }

    #[test]
    fn test_context_line_uses_shared_format_tool_display() {
        // Verify context_line uses the shared format_tool_display from session.rs
        let mut session = make_test_session("1", Status::Working, "proj1", "main");
        session.last_tool = Some("Bash".to_string());
        session.last_tool_detail = Some("npm test".to_string());
        let line = context_line(&session).unwrap();
        assert_eq!(line, "Running: npm test");

        // Edit shows filename (shared implementation behavior)
        session.last_tool = Some("Edit".to_string());
        session.last_tool_detail = Some("/very/long/path/to/file.rs".to_string());
        let line = context_line(&session).unwrap();
        assert!(line.starts_with("Editing "));
        assert!(line.contains("file.rs"));
    }

    #[test]
    fn test_four_group_height_calculation() {
        let sessions = vec![
            make_test_session("1", Status::WaitingPermission, "proj1", "main"),
            make_test_session("2", Status::WaitingInput, "proj2", "feature"),
            make_test_session("3", Status::Working, "proj3", "dev"),
            make_test_session("4", Status::Idle, "proj4", "main"),
        ];
        let total = sessions_total_height(&sessions);
        // 4 headers (28 each) + permission (62) + input (62) + working (62) + idle (44)
        let expected = (4.0 * HEADER_HEIGHT) + ROW_HEIGHT_WITH_CONTEXT * 3.0 + ROW_HEIGHT_MINIMAL;
        assert!((total - expected).abs() < 1.0);
    }
}
