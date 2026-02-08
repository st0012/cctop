//! egui popup rendering for the cctop menubar.
//!
//! Renders the session list popup as card-based "Claude Warm" design with
//! status dots, hover effects, branch chips, and proper styling.
//! Features an arrow pointing to the tray icon and rounded corners.

use crate::session::{
    format_relative_time, format_tool_display, truncate_prompt, GroupedSessions, Session, Status,
};
use egui::{
    epaint::PathShape, Color32, Pos2, Rect, RichText, Rounding, ScrollArea, Sense, Shape, Stroke,
    Vec2,
};
use std::time::Duration;

/// Special return value indicating the user clicked "Quit".
pub const QUIT_ACTION: &str = "__quit__";

// ── Layout constants ────────────────────────────────────────────────────────

/// Content dimensions.
pub const CONTENT_WIDTH: f32 = 320.0;
/// Padding around the content for rounded corners to be visible.
pub const WINDOW_PADDING: f32 = 1.0;
/// Total popup width including padding.
pub const POPUP_WIDTH: f32 = CONTENT_WIDTH + (WINDOW_PADDING * 2.0);

/// Outer border radius for the popup body.
pub const OUTER_RADIUS: f32 = 12.0;

/// Card layout constants.
pub const CARD_PADDING_H: f32 = 12.0;
pub const CARD_PADDING_V: f32 = 10.0;
pub const CARD_RADIUS: f32 = 10.0;
pub const CARD_GAP: f32 = 4.0;
/// Padding around the session card list area.
pub const SESSION_LIST_PADDING: f32 = 8.0;
/// Extra bottom padding in the session list (beyond SESSION_LIST_PADDING).
pub const SESSION_LIST_BOTTOM_EXTRA: f32 = 4.0;

/// Header layout constants.
pub const HEADER_PADDING_TOP: f32 = 14.0;
pub const HEADER_PADDING_BOTTOM: f32 = 12.0;
pub const HEADER_PADDING_H: f32 = 16.0;

/// Row height for the "No active sessions" fallback.
pub const ROW_HEIGHT_MINIMAL: f32 = 44.0;

pub const QUIT_ROW_HEIGHT: f32 = 36.0;

/// Arrow dimensions (pointing up to tray icon).
pub const ARROW_HEIGHT: f32 = 12.0;
pub const ARROW_WIDTH: f32 = 16.0;

/// Maximum height for the scrollable session content area.
const MAX_SCROLL_HEIGHT: f32 = 520.0;

// ── Color system ────────────────────────────────────────────────────────────

/// Colors for the "Claude Warm" design.
pub mod colors {
    use egui::Color32;

    // Backgrounds
    pub const BG: Color32 = Color32::from_rgb(26, 26, 26);
    pub const BG_ELEVATED: Color32 = Color32::from_rgb(35, 35, 35);
    pub const BG_SUBTLE: Color32 = Color32::from_rgb(42, 42, 42);
    pub const BG_HOVER: Color32 = Color32::from_rgb(51, 51, 51);

    // Borders
    pub const BORDER: Color32 = Color32::from_rgb(51, 51, 51);
    pub const BORDER_SUBTLE: Color32 = Color32::from_rgb(42, 42, 42);

    // Text
    pub const TEXT: Color32 = Color32::from_rgb(228, 228, 228);
    pub const TEXT_MUTED: Color32 = Color32::from_rgb(136, 136, 136);
    pub const TEXT_DIM: Color32 = Color32::from_rgb(102, 102, 102);

    // Brand
    pub const ORANGE: Color32 = Color32::from_rgb(232, 116, 67);

    // Status
    pub const STATUS_GREEN: Color32 = Color32::from_rgb(74, 222, 128);
    pub const STATUS_AMBER: Color32 = Color32::from_rgb(245, 158, 11);
    pub const STATUS_GRAY: Color32 = Color32::from_rgb(107, 114, 128);
    pub const STATUS_RED: Color32 = Color32::from_rgb(239, 68, 68);

    // Chip helpers (unified alpha values)
    pub fn chip_bg(base: Color32) -> Color32 {
        let [r, g, b, _] = base.to_array();
        Color32::from_rgba_unmultiplied(r, g, b, 0x18) // 9% alpha
    }
    pub fn chip_border(base: Color32) -> Color32 {
        let [r, g, b, _] = base.to_array();
        Color32::from_rgba_unmultiplied(r, g, b, 0x40) // 25% alpha
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Get the status dot color for a session status.
fn status_color(status: &Status) -> Color32 {
    match status {
        Status::WaitingPermission => colors::STATUS_RED,
        Status::WaitingInput | Status::NeedsAttention => colors::STATUS_AMBER,
        Status::Working => colors::STATUS_GREEN,
        Status::Idle => colors::STATUS_GRAY,
    }
}

/// Compute pulsing opacity for attention dots (1.5s cycle, 60-100% opacity).
fn pulsing_alpha(ctx: &egui::Context) -> f32 {
    let time = ctx.input(|i| i.time);
    let t = (time * std::f64::consts::TAU / 1.5).sin() as f32;
    0.8 + 0.2 * t // range [0.6, 1.0]
}

/// Get the context line text for a session (prompt / tool info).
/// Returns None for idle sessions or sessions with no context.
fn context_line(session: &Session) -> Option<String> {
    match session.status {
        Status::Idle => None,
        Status::WaitingPermission => Some(
            session
                .notification_message
                .as_ref()
                .map_or("Permission needed".to_string(), |msg| {
                    truncate_prompt(msg, 38)
                }),
        ),
        Status::WaitingInput | Status::NeedsAttention => session
            .last_prompt
            .as_ref()
            .map(|p| format!("\"{}\"", truncate_prompt(p, 36))),
        Status::Working => {
            if let Some(ref tool) = session.last_tool {
                Some(format_tool_display(
                    tool,
                    session.last_tool_detail.as_deref(),
                    38,
                ))
            } else {
                session
                    .last_prompt
                    .as_ref()
                    .map(|p| format!("\"{}\"", truncate_prompt(p, 36)))
            }
        }
    }
}

/// Card height: 54px with context line, 48px without.
fn card_height(session: &Session) -> f32 {
    if context_line(session).is_some() {
        54.0
    } else {
        48.0
    }
}

/// Linearly interpolate between two colors.
fn lerp_color(a: Color32, b: Color32, t: f32) -> Color32 {
    let [ar, ag, ab, aa] = a.to_array();
    let [br, bg, bb, ba] = b.to_array();
    Color32::from_rgba_unmultiplied(
        (ar as f32 + (br as f32 - ar as f32) * t) as u8,
        (ag as f32 + (bg as f32 - ag as f32) * t) as u8,
        (ab as f32 + (bb as f32 - ab as f32) * t) as u8,
        (aa as f32 + (ba as f32 - aa as f32) * t) as u8,
    )
}

/// Sort sessions by status priority (most urgent first).
fn sorted_by_priority(sessions: &[Session]) -> Vec<&Session> {
    let mut refs: Vec<&Session> = sessions.iter().collect();
    refs.sort_by_key(|s| match s.status {
        Status::WaitingPermission => 0,
        Status::WaitingInput | Status::NeedsAttention => 1,
        Status::Working => 2,
        Status::Idle => 3,
    });
    refs
}

// ── Arrow ───────────────────────────────────────────────────────────────────

/// Draw the arrow pointing up to the tray icon.
fn draw_arrow(painter: &egui::Painter, center_x: f32, top_y: f32) {
    let points = vec![
        Pos2::new(center_x, top_y),
        Pos2::new(center_x - ARROW_WIDTH / 2.0, top_y + ARROW_HEIGHT),
        Pos2::new(center_x + ARROW_WIDTH / 2.0, top_y + ARROW_HEIGHT),
    ];
    let shape = Shape::Path(PathShape::convex_polygon(points, colors::BG, Stroke::NONE));
    painter.add(shape);
}

// ── Header ──────────────────────────────────────────────────────────────────

/// Header height: padding_top + badge + padding_bottom + 1px border.
const HEADER_HEIGHT_TOTAL: f32 = HEADER_PADDING_TOP + 20.0 + HEADER_PADDING_BOTTOM + 1.0;

/// Render the header with "C" badge, "cctop" title, and summary chips.
fn render_header(ui: &mut egui::Ui, sessions: &[Session]) {
    let header_rect = Rect::from_min_size(
        ui.cursor().min,
        Vec2::new(CONTENT_WIDTH, HEADER_HEIGHT_TOTAL),
    );
    ui.allocate_rect(header_rect, Sense::hover());
    let painter = ui.painter();

    // Orange tint: skipped. Even alpha=3 produces a visibly strong tint
    // under PreMultiplied compositing on macOS. The "C" badge provides
    // enough orange accent for the header.

    // "C" badge: 20x20, radius 6, orange bg, white "C"
    let badge_x = header_rect.min.x + HEADER_PADDING_H;
    let badge_y = header_rect.min.y + HEADER_PADDING_TOP;
    let badge_rect = Rect::from_min_size(Pos2::new(badge_x, badge_y), Vec2::splat(20.0));
    painter.rect_filled(badge_rect, Rounding::same(6.0), colors::ORANGE);
    painter.text(
        badge_rect.center(),
        egui::Align2::CENTER_CENTER,
        "C",
        egui::FontId::proportional(12.0),
        Color32::WHITE,
    );

    // "cctop" title (14px, semibold, right of badge)
    painter.text(
        Pos2::new(badge_x + 20.0 + 8.0, badge_y + 10.0),
        egui::Align2::LEFT_CENTER,
        "cctop",
        egui::FontId::proportional(14.0),
        colors::TEXT,
    );

    // Summary chips (right-aligned)
    let grouped = GroupedSessions::from_sessions(sessions);
    let attention_count = grouped.waiting_permission.len() + grouped.waiting_input.len();
    let working_count = grouped.working.len();
    let idle_count = grouped.idle.len();

    // Chips are rendered right-to-left
    let mut chip_right = header_rect.max.x - HEADER_PADDING_H;
    let chip_y = badge_y + 3.0; // vertically align with badge center area

    // Render chips in order: idle, working, attention (right to left, so idle is rightmost)
    let chip_data: Vec<(usize, Color32)> = vec![
        (idle_count, colors::STATUS_GRAY),
        (working_count, colors::STATUS_GREEN),
        (attention_count, colors::STATUS_AMBER),
    ];

    for (count, color) in chip_data {
        if count == 0 {
            continue;
        }
        let count_text = count.to_string();
        let galley = painter.layout_no_wrap(count_text, egui::FontId::proportional(10.0), color);
        let dot_size = 5.0;
        let dot_gap = 4.0;
        let pad_h = 6.0;
        let chip_w = pad_h + dot_size + dot_gap + galley.size().x + pad_h;
        let chip_h = 16.0;

        let chip_rect = Rect::from_min_size(
            Pos2::new(chip_right - chip_w, chip_y),
            Vec2::new(chip_w, chip_h),
        );

        // Chip background and border
        painter.rect_filled(chip_rect, Rounding::same(10.0), colors::chip_bg(color));
        painter.rect_stroke(
            chip_rect,
            Rounding::same(10.0),
            Stroke::new(1.0, colors::chip_border(color)),
        );

        // Dot inside chip
        let dot_center = Pos2::new(
            chip_rect.min.x + pad_h + dot_size / 2.0,
            chip_rect.center().y,
        );
        painter.circle_filled(dot_center, dot_size / 2.0, color);

        // Count text
        painter.galley(
            Pos2::new(
                chip_rect.min.x + pad_h + dot_size + dot_gap,
                chip_rect.min.y + (chip_h - galley.size().y) / 2.0,
            ),
            galley,
            Color32::TRANSPARENT,
        );

        chip_right -= chip_w + 4.0; // gap between chips
    }

    // Bottom border
    let border_y = header_rect.max.y - 1.0;
    painter.rect_filled(
        Rect::from_min_size(
            Pos2::new(header_rect.min.x, border_y),
            Vec2::new(CONTENT_WIDTH, 1.0),
        ),
        Rounding::ZERO,
        colors::BORDER,
    );
}

// ── Session card ────────────────────────────────────────────────────────────

/// Card width: CONTENT_WIDTH minus list padding on each side.
const CARD_WIDTH: f32 = CONTENT_WIDTH - SESSION_LIST_PADDING * 2.0;

/// Render a branch chip (monospace text in BG_SUBTLE pill).
fn render_branch_chip(painter: &egui::Painter, pos: Pos2, branch: &str) {
    let galley = painter.layout_no_wrap(
        branch.to_string(),
        egui::FontId::monospace(10.0),
        colors::TEXT_DIM,
    );
    let chip_rect = Rect::from_min_size(
        pos,
        Vec2::new(galley.size().x + 10.0, galley.size().y + 2.0),
    );
    painter.rect_filled(chip_rect, Rounding::same(4.0), colors::BG_SUBTLE);
    painter.galley(
        Pos2::new(chip_rect.min.x + 5.0, chip_rect.min.y + 1.0),
        galley,
        Color32::TRANSPARENT,
    );
}

/// Render a status chip (uppercase label in colored pill, below time text on right side).
fn render_status_chip(painter: &egui::Painter, session: &Session, card_rect: Rect) {
    let (label, color) = match session.status {
        Status::WaitingPermission => ("PERMISSION", colors::STATUS_RED),
        Status::WaitingInput | Status::NeedsAttention => ("WAITING", colors::STATUS_AMBER),
        Status::Working => ("WORKING", colors::STATUS_GREEN),
        Status::Idle => ("IDLE", colors::STATUS_GRAY),
    };

    let galley = painter.layout_no_wrap(label.to_string(), egui::FontId::proportional(9.0), color);
    let pad_h = 6.0;
    let pad_v = 1.0;
    let chip_w = galley.size().x + pad_h * 2.0;
    let chip_h = galley.size().y + pad_v * 2.0;

    // Position below the time text: time is at CARD_PADDING_V+1, ~12px tall, then 4px gap
    let chip_rect = Rect::from_min_size(
        Pos2::new(
            card_rect.max.x - CARD_PADDING_H - chip_w,
            card_rect.min.y + CARD_PADDING_V + 18.0,
        ),
        Vec2::new(chip_w, chip_h),
    );

    painter.rect_filled(chip_rect, Rounding::same(4.0), colors::chip_bg(color));
    painter.rect_stroke(
        chip_rect,
        Rounding::same(4.0),
        Stroke::new(1.0, colors::chip_border(color)),
    );
    painter.galley(
        Pos2::new(chip_rect.min.x + pad_h, chip_rect.min.y + pad_v),
        galley,
        Color32::TRANSPARENT,
    );
}

/// Render a single session card.
/// Returns true if the card was clicked.
fn render_session_card(ui: &mut egui::Ui, session: &Session, pulse_alpha: Option<f32>) -> bool {
    let height = card_height(session);
    let card_rect = Rect::from_min_size(
        Pos2::new(ui.cursor().min.x + SESSION_LIST_PADDING, ui.cursor().min.y),
        Vec2::new(CARD_WIDTH, height),
    );

    // We need to allocate the full-width rect for interaction
    let alloc_rect = Rect::from_min_size(ui.cursor().min, Vec2::new(CONTENT_WIDTH, height));
    let response = ui.allocate_rect(alloc_rect, Sense::click());
    let is_hovered = response.hovered();
    let painter = ui.painter();

    // Smooth hover transition (0.15s)
    let dt = ui.ctx().input(|i| i.unstable_dt).max(1.0 / 120.0); // floor dt to avoid tiny steps
    let (hover_t, animating) = ui.ctx().data_mut(|d| {
        let t = d.get_temp_mut_or(egui::Id::new(("card_hover", &session.session_id)), 0.0f32);
        let target = if is_hovered { 1.0 } else { 0.0 };
        *t += (target - *t) * (6.7 * dt).min(1.0);
        let animating = (*t - target).abs() > 0.01;
        (*t, animating)
    });
    // Schedule repaint OUTSIDE data_mut to avoid deadlocking the context lock.
    if animating {
        ui.ctx().request_repaint_after(Duration::from_millis(33));
    }

    let bg_color = lerp_color(colors::BG_ELEVATED, colors::BG_SUBTLE, hover_t);
    let border_color = lerp_color(colors::BORDER_SUBTLE, colors::BORDER, hover_t);

    // Card background
    painter.rect_filled(card_rect, Rounding::same(CARD_RADIUS), bg_color);
    // Card border
    painter.rect_stroke(
        card_rect,
        Rounding::same(CARD_RADIUS),
        Stroke::new(1.0, border_color),
    );

    // Status dot (centered in 15px container: size=9, container=size+6)
    let dot_center = Pos2::new(
        card_rect.min.x + CARD_PADDING_H + 7.5, // center of 15px container
        card_rect.min.y + CARD_PADDING_V + 8.0, // vertically centered with name text
    );
    let base_color = status_color(&session.status);

    // Apply pulsing alpha to attention dots
    let dot_color = if let Some(alpha) = pulse_alpha {
        match session.status {
            Status::WaitingPermission | Status::WaitingInput | Status::NeedsAttention => {
                let [r, g, b, _] = base_color.to_array();
                Color32::from_rgba_unmultiplied(r, g, b, (alpha * 255.0) as u8)
            }
            _ => base_color,
        }
    } else {
        base_color
    };
    painter.circle_filled(dot_center, 4.5, dot_color);

    // Text positions: after 15px dot container + 8px gap
    let text_x = card_rect.min.x + CARD_PADDING_H + 15.0 + 8.0;

    // Project name (13px) - measure width for inline branch chip
    let name_galley = painter.layout_no_wrap(
        session.project_name.clone(),
        egui::FontId::proportional(13.0),
        colors::TEXT,
    );
    let name_width = name_galley.size().x;
    painter.galley(
        Pos2::new(text_x, card_rect.min.y + CARD_PADDING_V),
        name_galley,
        Color32::TRANSPARENT,
    );

    // Time (right-aligned, 10px)
    let time_text = format_relative_time(session.last_activity);
    painter.text(
        Pos2::new(
            card_rect.max.x - CARD_PADDING_H,
            card_rect.min.y + CARD_PADDING_V + 1.0,
        ),
        egui::Align2::RIGHT_TOP,
        &time_text,
        egui::FontId::proportional(10.0),
        colors::TEXT_DIM,
    );

    // Branch chip (inline with project name, 6px gap)
    let branch_text = if session.context_compacted {
        format!("{} [compacted]", session.branch)
    } else {
        session.branch.clone()
    };
    render_branch_chip(
        painter,
        Pos2::new(
            text_x + name_width + 6.0,
            card_rect.min.y + CARD_PADDING_V + 2.0,
        ),
        &branch_text,
    );

    // Status chip (bottom-right)
    render_status_chip(painter, session, card_rect);

    // Prompt text (if present, 11px) - marginTop:3 from name row (~16px tall)
    if let Some(context) = context_line(session) {
        painter.text(
            Pos2::new(text_x, card_rect.min.y + CARD_PADDING_V + 19.0),
            egui::Align2::LEFT_TOP,
            &context,
            egui::FontId::proportional(11.0),
            colors::TEXT_MUTED,
        );
    }

    response.clicked()
}

// ── Footer ──────────────────────────────────────────────────────────────────

/// Render the footer with a small "Quit" button at the bottom-left.
/// Right side is reserved for future settings. Returns true if clicked.
fn render_quit_row(ui: &mut egui::Ui) -> bool {
    let row_rect = Rect::from_min_size(ui.cursor().min, Vec2::new(CONTENT_WIDTH, QUIT_ROW_HEIGHT));
    // Allocate row height for layout (non-interactive)
    ui.allocate_rect(row_rect, Sense::hover());

    // Measure quit text to size the button
    let galley = ui.painter().layout_no_wrap(
        "Quit".to_string(),
        egui::FontId::proportional(11.0),
        colors::TEXT_DIM,
    );
    let pad_h = 8.0;
    let pad_v = 4.0;
    let btn_w = galley.size().x + pad_h * 2.0;
    let btn_h = galley.size().y + pad_v * 2.0;

    // Position at bottom-left of footer area
    let btn_rect = Rect::from_min_size(
        Pos2::new(
            row_rect.min.x + HEADER_PADDING_H,
            row_rect.center().y - btn_h / 2.0,
        ),
        Vec2::new(btn_w, btn_h),
    );

    // Interactive area for just the button
    let response = ui.interact(btn_rect, egui::Id::new("quit_btn"), Sense::click());

    if response.hovered() {
        ui.painter()
            .rect_filled(btn_rect, Rounding::same(4.0), colors::BG_HOVER);
    }

    ui.painter().galley(
        Pos2::new(btn_rect.min.x + pad_h, btn_rect.min.y + pad_v),
        galley,
        Color32::TRANSPARENT,
    );

    response.clicked()
}

// ── Height calculation ──────────────────────────────────────────────────────

/// Calculate the total height of session card content.
fn sessions_total_height(sessions: &[Session]) -> f32 {
    if sessions.is_empty() {
        ROW_HEIGHT_MINIMAL // "No active sessions" fallback
    } else {
        let cards_h: f32 = sessions.iter().map(card_height).sum();
        let gaps = (sessions.len().saturating_sub(1)) as f32 * CARD_GAP;
        cards_h + gaps + SESSION_LIST_PADDING * 2.0 + SESSION_LIST_BOTTOM_EXTRA
    }
}

/// Calculate the required popup height based on sessions.
/// This must match exactly what render_popup draws.
pub fn calculate_popup_height(sessions: &[Session]) -> f32 {
    let header_h = HEADER_HEIGHT_TOTAL;
    let cards_h = sessions_total_height(sessions);
    let footer_h = 1.0 + QUIT_ROW_HEIGHT; // border + quit row

    ARROW_HEIGHT + header_h + cards_h.min(MAX_SCROLL_HEIGHT) + footer_h + WINDOW_PADDING
}

// ── Main render ─────────────────────────────────────────────────────────────

/// Render the popup and return the clicked session ID (or QUIT_ACTION).
///
/// Returns `Some(session_id)` if a session was clicked,
/// `Some(QUIT_ACTION)` if quit was clicked,
/// or `None` if nothing was clicked.
pub fn render_popup(ctx: &egui::Context, sessions: &[Session]) -> Option<String> {
    let mut clicked_id: Option<String> = None;
    let screen_rect = ctx.screen_rect();
    let painter = ctx.layer_painter(egui::LayerId::background());

    // Draw arrow at top center
    let arrow_center_x = screen_rect.center().x;
    draw_arrow(&painter, arrow_center_x, 0.0);

    // Draw rounded content area below arrow (inset by WINDOW_PADDING)
    let content_rect = Rect::from_min_max(
        Pos2::new(WINDOW_PADDING, ARROW_HEIGHT),
        Pos2::new(
            screen_rect.max.x - WINDOW_PADDING,
            screen_rect.max.y - WINDOW_PADDING,
        ),
    );
    painter.rect_filled(content_rect, Rounding::same(OUTER_RADIUS), colors::BG);

    egui::Area::new(egui::Id::new("cctop_popup"))
        .fixed_pos(Pos2::new(WINDOW_PADDING, ARROW_HEIGHT))
        .show(ctx, |ui| {
            ui.set_width(CONTENT_WIDTH);

            // 1. Header
            render_header(ui, sessions);

            // 2. Scrollable card area
            let scroll_height = sessions_total_height(sessions).min(MAX_SCROLL_HEIGHT);

            // Compute pulsing alpha once for all attention dots
            let has_attention = sessions.iter().any(|s| s.status.needs_attention());
            let pulse_alpha = has_attention.then(|| pulsing_alpha(ui.ctx()));

            ScrollArea::vertical()
                .max_height(scroll_height)
                .auto_shrink([false, true])
                .show(ui, |ui| {
                    ui.set_width(CONTENT_WIDTH);

                    if sessions.is_empty() {
                        ui.add_space(8.0);
                        ui.horizontal(|ui| {
                            ui.add_space(16.0);
                            ui.label(
                                RichText::new("No active sessions")
                                    .color(colors::TEXT_MUTED)
                                    .size(13.0),
                            );
                        });
                        ui.add_space(8.0);
                    } else {
                        ui.add_space(SESSION_LIST_PADDING);
                        let sorted = sorted_by_priority(sessions);
                        let last_idx = sorted.len().saturating_sub(1);
                        for (i, session) in sorted.iter().enumerate() {
                            if render_session_card(ui, session, pulse_alpha) {
                                clicked_id = Some(session.session_id.clone());
                            }
                            if i < last_idx {
                                ui.add_space(CARD_GAP);
                            }
                        }
                        ui.add_space(SESSION_LIST_PADDING + SESSION_LIST_BOTTOM_EXTRA);
                    }

                    // Schedule periodic repaints for the pulsing animation
                    // (~30fps). Using request_repaint_after avoids an infinite
                    // repaint loop that would freeze the event loop.
                    if has_attention {
                        ui.ctx().request_repaint_after(Duration::from_millis(33));
                    }
                });

            // Footer separator (1px border)
            let sep_rect = Rect::from_min_size(ui.cursor().min, Vec2::new(CONTENT_WIDTH, 1.0));
            ui.painter()
                .rect_filled(sep_rect, Rounding::ZERO, colors::BORDER);
            ui.allocate_rect(sep_rect, Sense::hover());

            // Quit row
            if render_quit_row(ui) {
                clicked_id = Some(QUIT_ACTION.to_string());
            }
        });

    clicked_id
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

    fn make_test_session_no_prompt(
        id: &str,
        status: Status,
        project: &str,
        branch: &str,
    ) -> Session {
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
        assert_eq!(status_color(&Status::WaitingPermission), colors::STATUS_RED);
        assert_eq!(status_color(&Status::WaitingInput), colors::STATUS_AMBER);
        assert_eq!(status_color(&Status::NeedsAttention), colors::STATUS_AMBER);
        assert_eq!(status_color(&Status::Working), colors::STATUS_GREEN);
        assert_eq!(status_color(&Status::Idle), colors::STATUS_GRAY);
    }

    #[test]
    fn test_card_height_idle_is_small() {
        let session = make_test_session("1", Status::Idle, "proj1", "main");
        assert_eq!(card_height(&session), 48.0);
    }

    #[test]
    fn test_card_height_working_with_prompt_is_tall() {
        let session = make_test_session("1", Status::Working, "proj1", "main");
        assert_eq!(card_height(&session), 54.0);
    }

    #[test]
    fn test_card_height_working_without_prompt_is_small() {
        let session = make_test_session_no_prompt("1", Status::Working, "proj1", "main");
        assert_eq!(card_height(&session), 48.0);
    }

    #[test]
    fn test_card_height_waiting_input_with_prompt_is_tall() {
        let session = make_test_session("1", Status::WaitingInput, "proj1", "main");
        assert_eq!(card_height(&session), 54.0);
    }

    #[test]
    fn test_card_height_waiting_permission_is_tall() {
        let session = make_test_session("1", Status::WaitingPermission, "proj1", "main");
        // WaitingPermission always shows context ("Permission needed")
        assert_eq!(card_height(&session), 54.0);
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
        // header + fallback + footer + arrow + padding
        let expected = ARROW_HEIGHT
            + HEADER_HEIGHT_TOTAL
            + ROW_HEIGHT_MINIMAL
            + 1.0
            + QUIT_ROW_HEIGHT
            + WINDOW_PADDING;
        assert!(
            (height - expected).abs() < 1.0,
            "height={}, expected={}",
            height,
            expected
        );
    }

    #[test]
    fn test_calculate_popup_height_with_sessions() {
        let sessions = vec![
            make_test_session("1", Status::Idle, "proj1", "main"),
            make_test_session("2", Status::Working, "proj2", "feature"),
        ];
        let height = calculate_popup_height(&sessions);
        // idle card (48) + working card with prompt (54) + 1 gap (4) + list padding (8*2) + bottom extra (4)
        let expected_cards =
            48.0 + 54.0 + CARD_GAP + SESSION_LIST_PADDING * 2.0 + SESSION_LIST_BOTTOM_EXTRA;
        let expected = ARROW_HEIGHT
            + HEADER_HEIGHT_TOTAL
            + expected_cards
            + 1.0
            + QUIT_ROW_HEIGHT
            + WINDOW_PADDING;
        assert!(
            (height - expected).abs() < 1.0,
            "height={}, expected={}",
            height,
            expected
        );
    }

    #[test]
    fn test_calculate_popup_height_capped() {
        // Create many sessions to exceed MAX_SCROLL_HEIGHT
        let mut sessions = Vec::new();
        for i in 0..20 {
            sessions.push(make_test_session(
                &format!("{}", i),
                Status::Working,
                &format!("proj{}", i),
                "main",
            ));
        }
        let height = calculate_popup_height(&sessions);
        let max_height = ARROW_HEIGHT
            + HEADER_HEIGHT_TOTAL
            + MAX_SCROLL_HEIGHT
            + 1.0
            + QUIT_ROW_HEIGHT
            + WINDOW_PADDING;
        assert!(
            height <= max_height + 1.0,
            "Height {} should be capped at ~{}",
            height,
            max_height
        );
    }

    #[test]
    fn test_variable_height_mixed_sessions() {
        let sessions = vec![
            make_test_session("1", Status::Idle, "proj1", "main"), // 48px
            make_test_session("2", Status::Working, "proj2", "feature"), // 54px
            make_test_session_no_prompt("3", Status::Working, "proj3", "dev"), // 48px (no prompt)
        ];
        let total = sessions_total_height(&sessions);
        // 48 + 54 + 48 + 2 gaps (4 each) + list padding (8*2) + bottom extra (4)
        let expected = 48.0
            + 54.0
            + 48.0
            + 2.0 * CARD_GAP
            + SESSION_LIST_PADDING * 2.0
            + SESSION_LIST_BOTTOM_EXTRA;
        assert!(
            (total - expected).abs() < 1.0,
            "total={}, expected={}",
            total,
            expected
        );
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
    fn test_context_line_uses_shared_format_tool_display() {
        let mut session = make_test_session("1", Status::Working, "proj1", "main");
        session.last_tool = Some("Bash".to_string());
        session.last_tool_detail = Some("npm test".to_string());
        let line = context_line(&session).unwrap();
        assert_eq!(line, "Running: npm test");

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
        // 3 cards with context (54 each) + 1 idle card (48) + 3 gaps (4 each) + list padding (8*2) + bottom extra (4)
        let expected = 54.0 * 3.0
            + 48.0
            + 3.0 * CARD_GAP
            + SESSION_LIST_PADDING * 2.0
            + SESSION_LIST_BOTTOM_EXTRA;
        assert!(
            (total - expected).abs() < 1.0,
            "total={}, expected={}",
            total,
            expected
        );
    }

    #[test]
    fn test_sorted_by_priority() {
        let sessions = vec![
            make_test_session("1", Status::Idle, "proj1", "main"),
            make_test_session("2", Status::Working, "proj2", "feature"),
            make_test_session("3", Status::WaitingInput, "proj3", "fix"),
            make_test_session("4", Status::WaitingPermission, "proj4", "hotfix"),
        ];
        let sorted = sorted_by_priority(&sessions);
        assert_eq!(sorted[0].session_id, "4"); // WaitingPermission first
        assert_eq!(sorted[1].session_id, "3"); // WaitingInput second
        assert_eq!(sorted[2].session_id, "2"); // Working third
        assert_eq!(sorted[3].session_id, "1"); // Idle last
    }

    #[test]
    fn test_lerp_color() {
        let a = Color32::from_rgb(0, 0, 0);
        let b = Color32::from_rgb(100, 200, 50);
        let mid = lerp_color(a, b, 0.5);
        assert_eq!(mid, Color32::from_rgba_unmultiplied(50, 100, 25, 255));
    }

    #[test]
    fn test_card_width_constant() {
        assert_eq!(CARD_WIDTH, CONTENT_WIDTH - SESSION_LIST_PADDING * 2.0);
        assert_eq!(CARD_WIDTH, 304.0);
    }

    #[test]
    fn test_header_height_total() {
        assert_eq!(HEADER_HEIGHT_TOTAL, 47.0);
    }

    #[test]
    fn test_popup_width() {
        assert_eq!(POPUP_WIDTH, CONTENT_WIDTH + WINDOW_PADDING * 2.0);
        assert_eq!(POPUP_WIDTH, 322.0);
    }
}
