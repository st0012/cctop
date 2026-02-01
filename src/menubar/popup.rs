//! egui popup rendering for the cctop menubar.
//!
//! Renders the session list popup with status dots, hover effects, and proper styling.

use crate::session::{GroupedSessions, Session, Status};
use egui::{Color32, Frame, Margin, Pos2, Rect, RichText, Rounding, Sense, Vec2};

/// Special return value indicating the user clicked "Quit".
pub const QUIT_ACTION: &str = "__quit__";

/// Popup dimensions.
pub const POPUP_WIDTH: f32 = 288.0;
pub const ROW_HEIGHT: f32 = 44.0;
pub const HEADER_HEIGHT: f32 = 28.0;
pub const QUIT_ROW_HEIGHT: f32 = 36.0;

/// Colors matching the Minimal design.
pub mod colors {
    use egui::Color32;

    /// Background color: rgb(31, 41, 55) at ~95% opacity
    pub fn background() -> Color32 {
        Color32::from_rgba_unmultiplied(31, 41, 55, 242)
    }
    /// Hover color: rgba(255, 255, 255, 0.1)
    pub fn hover() -> Color32 {
        Color32::from_rgba_unmultiplied(255, 255, 255, 26)
    }
    /// Primary text color: white
    pub const TEXT_PRIMARY: Color32 = Color32::WHITE;
    /// Secondary text color: rgb(156, 163, 175)
    pub const TEXT_SECONDARY: Color32 = Color32::from_rgb(156, 163, 175);
    /// Status amber: rgb(245, 158, 11) - Needs Attention
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
        Status::NeedsAttention => colors::STATUS_AMBER,
        Status::Working => colors::STATUS_GREEN,
        Status::Idle => colors::STATUS_GRAY,
    }
}

/// Render the popup and return the clicked session ID (or QUIT_ACTION).
///
/// Returns `Some(session_id)` if a session was clicked,
/// `Some(QUIT_ACTION)` if quit was clicked,
/// or `None` if nothing was clicked.
pub fn render_popup(ctx: &egui::Context, sessions: &[Session]) -> Option<String> {
    let mut clicked_id: Option<String> = None;
    let grouped = GroupedSessions::from_sessions(sessions);

    // Paint background to fill entire window (no rounding to avoid black corner leak)
    ctx.layer_painter(egui::LayerId::background())
        .rect_filled(ctx.screen_rect(), Rounding::ZERO, colors::background());

    egui::Area::new(egui::Id::new("cctop_popup"))
        .fixed_pos(Pos2::new(0.0, 0.0))
        .show(ctx, |ui| {
            Frame::none()
                .inner_margin(Margin::symmetric(0.0, FRAME_VERTICAL_PADDING))
                .show(ui, |ui| {
                    ui.set_width(POPUP_WIDTH);

                    // Render each section
                    if let Some(id) = render_section(ui, "NEEDS ATTENTION", &grouped.needs_attention) {
                        clicked_id = Some(id);
                    }
                    if let Some(id) = render_section(ui, "WORKING", &grouped.working) {
                        clicked_id = Some(id);
                    }
                    if let Some(id) = render_section(ui, "IDLE", &grouped.idle) {
                        clicked_id = Some(id);
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

                    // Separator
                    ui.add_space(4.0);
                    let separator_rect = Rect::from_min_size(ui.cursor().min, Vec2::new(POPUP_WIDTH, 1.0));
                    ui.painter().rect_filled(separator_rect, 0.0, colors::separator());
                    ui.add_space(5.0);

                    // Quit row
                    if render_quit_row(ui) {
                        clicked_id = Some(QUIT_ACTION.to_string());
                    }
                });
        });

    clicked_id
}

/// Render a section with header and session rows.
/// Returns the clicked session ID if any row was clicked.
fn render_section(ui: &mut egui::Ui, header: &str, sessions: &[&Session]) -> Option<String> {
    if sessions.is_empty() {
        return None;
    }
    render_section_header(ui, header);
    for session in sessions {
        if render_session_row(ui, session) {
            return Some(session.session_id.clone());
        }
    }
    None
}

/// Render a section header (e.g., "NEEDS ATTENTION", "WORKING", "IDLE").
fn render_section_header(ui: &mut egui::Ui, text: &str) {
    ui.add_space(4.0);
    ui.horizontal(|ui| {
        ui.add_space(16.0);
        ui.label(
            RichText::new(text)
                .color(colors::TEXT_SECONDARY)
                .size(10.0)
                .strong(),
        );
    });
    ui.add_space(2.0);
}

/// Render a session row with status dot, project name, and branch.
/// Returns true if the row was clicked.
fn render_session_row(ui: &mut egui::Ui, session: &Session) -> bool {
    let row_rect = Rect::from_min_size(
        ui.cursor().min,
        Vec2::new(POPUP_WIDTH, ROW_HEIGHT),
    );

    // Handle interaction
    let response = ui.allocate_rect(row_rect, Sense::click());
    let is_hovered = response.hovered();

    // Draw hover background
    if is_hovered {
        ui.painter().rect_filled(row_rect, 0.0, colors::hover());
    }

    // Draw status dot
    let dot_center = Pos2::new(row_rect.min.x + 24.0, row_rect.min.y + 16.0);
    let dot_color = status_color(&session.status);
    ui.painter().circle_filled(dot_center, 4.0, dot_color);

    // Draw project name
    let text_x = row_rect.min.x + 40.0;
    ui.painter().text(
        Pos2::new(text_x, row_rect.min.y + 10.0),
        egui::Align2::LEFT_TOP,
        &session.project_name,
        egui::FontId::proportional(14.0),
        colors::TEXT_PRIMARY,
    );

    // Draw branch name
    ui.painter().text(
        Pos2::new(text_x, row_rect.min.y + 26.0),
        egui::Align2::LEFT_TOP,
        &session.branch,
        egui::FontId::proportional(11.0),
        colors::TEXT_SECONDARY,
    );

    response.clicked()
}

/// Render the "Quit cctop" row.
/// Returns true if clicked.
fn render_quit_row(ui: &mut egui::Ui) -> bool {
    let row_rect = Rect::from_min_size(
        ui.cursor().min,
        Vec2::new(POPUP_WIDTH, QUIT_ROW_HEIGHT),
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

/// Calculate section height (header + rows).
fn section_height(count: usize) -> f32 {
    if count == 0 {
        0.0
    } else {
        HEADER_HEIGHT + (count as f32 * ROW_HEIGHT)
    }
}

/// Calculate the required popup height based on sessions.
/// This must match exactly what render_popup draws.
pub fn calculate_popup_height(sessions: &[Session]) -> f32 {
    let grouped = GroupedSessions::from_sessions(sessions);

    let mut content_height = section_height(grouped.needs_attention.len())
        + section_height(grouped.working.len())
        + section_height(grouped.idle.len());

    if !grouped.has_any() {
        content_height += ROW_HEIGHT; // "No active sessions" message
    }

    // Separator (4.0 + 1.0 + 5.0) + quit row + frame padding
    content_height + 10.0 + QUIT_ROW_HEIGHT + (FRAME_VERTICAL_PADDING * 2.0)
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
        assert_eq!(status_color(&Status::NeedsAttention), colors::STATUS_AMBER);
        assert_eq!(status_color(&Status::Working), colors::STATUS_GREEN);
        assert_eq!(status_color(&Status::Idle), colors::STATUS_GRAY);
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
        let expected_min = (FRAME_VERTICAL_PADDING * 2.0) + (2.0 * HEADER_HEIGHT) + (2.0 * ROW_HEIGHT) + 10.0 + QUIT_ROW_HEIGHT;
        assert!(height >= expected_min);
    }
}
