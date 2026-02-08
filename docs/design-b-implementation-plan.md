# Design B ("Claude Warm") - Implementation Plan

## Overview

Redesign the cctop menubar popup from flat section-header layout to card-based "Claude Warm" design. All rendering changes are in egui 0.29 code. No dependency upgrades needed. Every Design B element is implementable.

## Files Changed

| File | Scope |
|------|-------|
| `src/menubar/popup.rs` | Major rewrite -- colors, layout, rendering |
| `src/menubar/app.rs` | Width constant reference, popup height calculation |
| `src/menubar/renderer.rs` | Optional: SF Mono font loading |

## Design Decisions (Open Questions Resolved)

| Question | Decision | Rationale |
|----------|----------|-----------|
| Arrow to tray icon | **Keep** | Good UX, macOS convention, already implemented, zero cost |
| Chip border alpha (summary vs status) | **Unify to 0x40** | 6% alpha difference is imperceptible |
| Header gradient | **Flat fill at 3% opacity** | Indistinguishable from gradient, avoids workaround |
| Box shadow on popup | **Skip** | macOS compositor provides depth; window is sized to content with no bleed margin |
| Glow on status dots | **Concentric circles** | 3 layers with decreasing alpha; convincing on dark bg |
| Hover transitions | **Frame-lerped 0.15s** via `ctx.data_mut()` | Perceptually identical to CSS transition |
| Pulse animation style | **Keep current sine-wave** | Simpler than expanding ring, already works |
| Footer "Cmd+K" shortcut | **Skip** | No keyboard shortcut system exists yet; avoid non-functional UI |
| SF Mono font | **Use egui built-in monospace initially** | Avoid system path dependency; revisit if visual mismatch is jarring |
| Prompt maxWidth | **Dynamic calculation** based on card width minus right column, not hardcoded 200px |

---

## Phase 1: Color System + Constants

**No visual change yet -- foundation for all subsequent phases.**

### Step 1.1: Replace `colors` module in popup.rs

```rust
pub mod colors {
    use egui::Color32;

    // Backgrounds
    pub const BG: Color32 = Color32::from_rgb(26, 26, 26);            // #1A1A1A
    pub const BG_ELEVATED: Color32 = Color32::from_rgb(35, 35, 35);   // #232323 (card)
    pub const BG_SUBTLE: Color32 = Color32::from_rgb(42, 42, 42);     // #2A2A2A (hover/chip)
    pub const BG_HOVER: Color32 = Color32::from_rgb(51, 51, 51);      // #333333

    // Borders
    pub const BORDER: Color32 = Color32::from_rgb(51, 51, 51);        // #333333
    pub const BORDER_SUBTLE: Color32 = Color32::from_rgb(42, 42, 42); // #2A2A2A

    // Text
    pub const TEXT: Color32 = Color32::from_rgb(228, 228, 228);        // #E4E4E4
    pub const TEXT_MUTED: Color32 = Color32::from_rgb(136, 136, 136);  // #888888
    pub const TEXT_DIM: Color32 = Color32::from_rgb(102, 102, 102);    // #666666

    // Brand
    pub const ORANGE: Color32 = Color32::from_rgb(232, 116, 67);      // #E87443

    // Status
    pub const STATUS_GREEN: Color32 = Color32::from_rgb(74, 222, 128); // #4ADE80
    pub const STATUS_AMBER: Color32 = Color32::from_rgb(245, 158, 11); // #F59E0B
    pub const STATUS_GRAY: Color32 = Color32::from_rgb(107, 114, 128); // #6B7280
    pub const STATUS_RED: Color32 = Color32::from_rgb(239, 68, 68);    // #EF4444

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
```

### Step 1.2: Replace layout constants

```rust
pub const CONTENT_WIDTH: f32 = 320.0;       // was 288.0
pub const POPUP_WIDTH: f32 = CONTENT_WIDTH + (WINDOW_PADDING * 2.0);
pub const OUTER_RADIUS: f32 = 12.0;         // was 7.0 (BORDER_RADIUS)
pub const CARD_PADDING_H: f32 = 12.0;
pub const CARD_PADDING_V: f32 = 10.0;
pub const CARD_RADIUS: f32 = 10.0;
pub const CARD_GAP: f32 = 4.0;
pub const SESSION_LIST_PADDING: f32 = 8.0;
pub const HEADER_PADDING_TOP: f32 = 14.0;
pub const HEADER_PADDING_BOTTOM: f32 = 12.0;
pub const HEADER_PADDING_H: f32 = 16.0;
pub const QUIT_ROW_HEIGHT: f32 = 36.0;      // unchanged
pub const ARROW_HEIGHT: f32 = 12.0;         // unchanged (keeping arrow)
pub const ARROW_WIDTH: f32 = 16.0;          // unchanged
pub const WINDOW_PADDING: f32 = 1.0;        // unchanged
const MAX_SCROLL_HEIGHT: f32 = 440.0;       // unchanged
```

### Step 1.3: Update `draw_arrow` to use new background color

Change `colors::background()` to `colors::BG` in the arrow fill.

---

## Phase 2: Header Redesign

### Step 2.1: New `render_header` function

Renders: orange tint background, "C" badge (20x20, radius 6, orange bg, white "C"), "cctop" title (14px semibold), summary chips (right-aligned), bottom border.

**Header height**: `HEADER_PADDING_TOP + 20.0 + HEADER_PADDING_BOTTOM` = 46px + 1px border = 47px total.

**Orange tint**: Single `rect_filled` with `Color32::from_rgba_unmultiplied(232, 116, 67, 8)` covering the header area.

**"C" badge**: `rect_filled` with `Rounding::same(6.0)` + centered `painter.text()`.

**Summary chips**: Right-to-left layout. For each non-zero status count:
- Measure count text with `painter.layout_no_wrap()`
- Calculate chip width: `6 + 5 + 4 + text_width + 6` (padding + dot + gap + text + padding)
- Pill border-radius: `Rounding::same(10.0)` for fully rounded pill

### Step 2.2: Summary chip status grouping

| Chip | Counts | Color |
|------|--------|-------|
| Attention | waiting_permission + waiting_input + needs_attention | STATUS_AMBER |
| Working | working | STATUS_GREEN |
| Idle | idle | STATUS_GRAY |

Hide chips with count 0.

---

## Phase 3: Card-Based Session Rendering

**This is the largest change.** Replaces `render_section()` + `render_section_header()` + `render_session_row()` with `render_session_card()`.

### Step 3.1: Session ordering

Sessions are still sorted by status priority (waiting_permission > waiting_input > working > idle) but rendered as a **flat list of cards** with no section headers. Each card self-identifies via its status chip.

### Step 3.2: `render_session_card` function

**Card rect**: width = `CONTENT_WIDTH - SESSION_LIST_PADDING * 2.0` (304px), height = 60px (with prompt) or 42px (without).

**Drawing order** (back to front):
1. Card background: `rect_filled(card_rect, Rounding::same(10.0), bg_color)`
2. Card border: `rect_stroke(card_rect, Rounding::same(10.0), Stroke::new(1.0, border_color))`
3. Status dot glow (if non-idle): 3 concentric `circle_filled` with radii 10.5/8.5/6.5 and alpha 5/7/15
4. Status dot: `circle_filled(center, 4.5, dot_color)` -- 9px diameter per spec
5. Project name: `painter.text()` at 13px, `colors::TEXT`
6. Branch chip: monospace text in `BG_SUBTLE` pill with `Rounding::same(4.0)`, no border
7. Time: right-aligned at 10px, `colors::TEXT_DIM`
8. Status chip: uppercase label in colored pill with border (bottom-right)
9. Prompt text (if present): 11px, `colors::TEXT_MUTED`, dynamically truncated

**Hover state**: bg toggles between `BG_ELEVATED` and `BG_SUBTLE`, border toggles between `BORDER_SUBTLE` and `BORDER`.

**Card spacing**: `ui.add_space(CARD_GAP)` after each card except the last.

### Step 3.3: `render_branch_chip` helper

```rust
fn render_branch_chip(painter: &egui::Painter, pos: Pos2, branch: &str) {
    let galley = painter.layout_no_wrap(
        branch.to_string(), FontId::monospace(10.0), colors::TEXT_DIM,
    );
    let chip_rect = Rect::from_min_size(pos, Vec2::new(
        galley.size().x + 10.0,  // 5px padding each side
        galley.size().y + 2.0,   // 1px padding each side
    ));
    painter.rect_filled(chip_rect, Rounding::same(4.0), colors::BG_SUBTLE);
    painter.galley(
        Pos2::new(chip_rect.min.x + 5.0, chip_rect.min.y + 1.0),
        galley, Color32::TRANSPARENT,
    );
}
```

### Step 3.4: `render_status_chip` helper

Position: bottom-right of card. Labels: "PERMISSION" (red), "WAITING" (amber), "WORKING" (green), "IDLE" (gray).

```rust
fn render_status_chip(painter: &egui::Painter, session: &Session, card_rect: Rect) {
    let (label, color) = match session.status {
        Status::WaitingPermission => ("PERMISSION", colors::STATUS_RED),
        Status::WaitingInput | Status::NeedsAttention => ("WAITING", colors::STATUS_AMBER),
        Status::Working => ("WORKING", colors::STATUS_GREEN),
        Status::Idle => ("IDLE", colors::STATUS_GRAY),
    };
    // Measure text, build chip rect, draw bg + border + text
    // Font: 9px proportional (egui approximation of 600 weight uppercase)
    // Padding: 6px horizontal, 1px vertical
    // Border radius: 4px
}
```

### Step 3.5: Prompt text truncation

Available prompt width: card width (304) - left padding (12) - dot area (21) - right column (~65) - right padding (12) = ~194px. At 11px proportional, roughly 30-32 characters before truncation.

---

## Phase 4: Footer + Height Calculation

### Step 4.1: Simplified footer

- Top border: 1px `colors::BORDER`
- "Quit" text left-aligned, 11px, `colors::TEXT_DIM`
- No "Cmd+K" (deferred until keyboard shortcuts exist)
- Hover: `BG_HOVER` background fill

### Step 4.2: Updated `calculate_popup_height`

```rust
pub fn calculate_popup_height(sessions: &[Session]) -> f32 {
    let header_h = HEADER_PADDING_TOP + 20.0 + HEADER_PADDING_BOTTOM + 1.0; // 47px
    let cards_h = if sessions.is_empty() {
        ROW_HEIGHT_MINIMAL // "No active sessions" fallback
    } else {
        sessions.iter().map(|s| card_height(s)).sum::<f32>()
            + (sessions.len().saturating_sub(1) as f32 * CARD_GAP)
            + SESSION_LIST_PADDING * 2.0
    };
    let footer_h = 1.0 + QUIT_ROW_HEIGHT; // border + quit row

    ARROW_HEIGHT + header_h + cards_h.min(MAX_SCROLL_HEIGHT) + footer_h + WINDOW_PADDING
}

fn card_height(session: &Session) -> f32 {
    if context_line(session).is_some() { 60.0 } else { 42.0 }
}
```

### Step 4.3: Update `render_popup` main function

Replace the current section-based loop with:
```rust
// 1. render_header(ui, sessions)
// 2. ScrollArea for cards:
//    - Sort sessions by status priority
//    - for (i, session) in sorted_sessions.iter().enumerate() {
//        render_session_card(ui, session, i == last_index)
//    }
// 3. Separator + render_footer(ui)
```

---

## Phase 5: Polish (Can Be Deferred)

### Step 5.1: Smooth hover transitions (0.15s)

Use egui's `ctx.data_mut()` ephemeral storage for per-card hover animation state:

```rust
let dt = ui.ctx().input(|i| i.unstable_dt);
let hover_t: f32 = ui.ctx().data_mut(|d| {
    let t = d.get_temp_mut_or(egui::Id::new(("card_hover", &session.session_id)), 0.0f32);
    let target = if is_hovered { 1.0 } else { 0.0 };
    *t += (target - *t) * (6.7 * dt).min(1.0); // ~0.15s ease
    if (*t - target).abs() > 0.01 {
        ui.ctx().request_repaint();
    }
    *t
});
// Lerp bg: BG_ELEVATED -> BG_SUBTLE using hover_t
// Lerp border: BORDER_SUBTLE -> BORDER using hover_t
```

### Step 5.2: Pulsing attention dots

Preserve existing sine-wave pulse from `pulsing_alpha()` (1.5s period, 60-100% range). Apply to individual card dots for waiting_permission and waiting_input statuses.

### Step 5.3: Optional SF Mono font loading

Only if built-in monospace looks wrong:
```rust
// In Renderer::new(), after egui_ctx creation:
if let Ok(data) = std::fs::read("/System/Library/Fonts/SFMono-Regular.otf") {
    let mut fonts = egui::FontDefinitions::default();
    fonts.font_data.insert("SF Mono".to_owned(), egui::FontData::from_owned(data));
    fonts.families.get_mut(&egui::FontFamily::Monospace).unwrap()
        .insert(0, "SF Mono".to_owned());
    egui_ctx.set_fonts(fonts);
}
```

---

## Implementation Order & Dependencies

```
Phase 1 (colors + constants)
    |
    +---> Phase 2 (header)     -- independent
    |
    +---> Phase 3 (cards)      -- independent, can parallel with Phase 2
              |
              +---> Phase 4 (footer + height calc) -- depends on card heights
                        |
                        +---> Phase 5 (polish) -- independent, deferrable
```

Given that popup.rs is the bottleneck file, **solo sequential work is most efficient**.

---

## macOS Platform Considerations

| Concern | Resolution |
|---------|-----------|
| Width increase 288->320px | Check `calculate_popup_position` for screen-edge clamping |
| Retina 1px borders | `rect_stroke` at 1.0 logical px = 2 physical px on Retina; acceptable |
| Transparent window compositing | Already handled: `PreMultiplied` alpha + `CAMetalLayer.setOpaque(false)` |
| Semi-transparent overlapping elements | Alpha compositing correct in wgpu; draw order matters |
| Power usage from animation repaints | Bounded: hover adds ~10 frames per event |
| Font access | Not sandboxed; `/System/Library/Fonts/` readable |

---

## Design Compromises

| Design Spec | Implementation | Visual Impact |
|-------------|---------------|---------------|
| Linear gradient header | Flat 3% orange fill | Imperceptible |
| Box shadow on popup | OS compositor shadow | Slightly less dramatic depth |
| Gaussian glow on dots | 3 concentric circles | Convincing approximation |
| CSS animate-ping | Sine-wave alpha pulse | Same attention signal |
| Font weight 500/600/700 | Bold or regular only | Minor weight variation lost |
| SF Mono for branch | egui built-in monospace | Slightly different letterforms |
| 0.15s CSS ease transition | Frame-lerped exponential | Perceptually identical |
| Footer "Cmd+K" | Omitted | No non-functional UI |
