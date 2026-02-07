# Menubar App Redesign

## Overview

Improve the cctop menubar popup to match the tauri-menubar-app reference design, with an arrow pointing to the tray icon and rounded corners. Also refactor the monolithic binary into clean modules.

## Visual Design

### Arrow + Rounded Container

```
        ▲           ← 12px tall triangle (centered)
   ┌─────────────────────────────────┐
   │  ● project-name                 │  ← 7px border radius
   │    feature/branch               │
   │  ● another-project              │
   │    main                         │
   ├─────────────────────────────────┤
   │  IDLE                           │
   │  ○ docs-site                    │
   │    main                         │
   ├─────────────────────────────────┤
   │  Quit cctop                     │
   └─────────────────────────────────┘  ← 7px border radius
```

### Constants

| Constant | Value | Notes |
|----------|-------|-------|
| `ARROW_HEIGHT` | 12.0 | Triangle height |
| `ARROW_WIDTH` | 16.0 | Triangle base (8px each side) |
| `BORDER_RADIUS` | 7.0 | Rounded corners |
| `BACKGROUND_COLOR` | `#2f2f2f` | Match reference |
| `POPUP_WIDTH` | 288.0 | Unchanged |

### Drawing Order

1. Clear window to transparent
2. Draw arrow triangle at top center
3. Draw rounded rectangle for content area below arrow
4. Draw session rows, separators, quit button inside content area

## Architecture

### Current State

`src/bin/cctop_menubar.rs` (526 lines) mixes:
- wgpu initialization
- Surface configuration
- Event loop handling
- Input processing
- Rendering logic

### Target Structure

```
src/menubar/
├── mod.rs              # Exports
├── popup.rs            # UI rendering (update)
├── popup_state.rs      # State management (unchanged)
├── renderer.rs         # NEW: wgpu + egui encapsulation
└── app.rs              # NEW: Event loop and coordination

src/bin/
└── cctop_menubar.rs    # Slim entry point (~20 lines)
```

### Module Responsibilities

**renderer.rs** (~150 lines)
- `Renderer::new(window)` - Creates wgpu device, surface, egui context
- `Renderer::resize(size, scale_factor)` - Handles window/display changes
- `Renderer::render<F>(draw_fn: F)` - Executes render pass with callback
- Encapsulates all GPU boilerplate, texture management

**app.rs** (~200 lines)
- `MenubarApp` struct: holds Renderer, PopupState, sessions, watcher, config
- `MenubarApp::run()` - Creates window, tray, runs event loop
- Event handlers: tray click, keyboard (ESC), mouse input, focus
- Session change polling

**popup.rs** (update)
- Add `draw_arrow(painter, center_x, top_y)` function
- Update `render_popup()` to draw arrow + rounded content area
- Change background color to `#2f2f2f`
- Adjust content positioning to account for arrow

**cctop_menubar.rs** (~20 lines)
```rust
#[cfg(target_os = "macos")]
fn main() {
    if let Err(e) = cctop::menubar::app::MenubarApp::run() {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}
```

## Implementation Order

1. Create `renderer.rs` - Extract wgpu/egui setup from current binary
2. Create `app.rs` - Extract event loop and state management
3. Update `popup.rs` - Add arrow, rounded corners, new colors
4. Simplify `cctop_menubar.rs` - Reduce to entry point
5. Test and verify visual appearance

## Files Changed

| File | Action |
|------|--------|
| `src/menubar/renderer.rs` | Create |
| `src/menubar/app.rs` | Create |
| `src/menubar/popup.rs` | Modify |
| `src/menubar/mod.rs` | Modify |
| `src/bin/cctop_menubar.rs` | Simplify |

## Reference

- tauri-menubar-app: CSS arrow technique with `::before` pseudo-element
- Arrow: `border-width: 0 8px 12px 8px` creates upward triangle
- Background: `#2f2f2f`, border-radius: `7px`
