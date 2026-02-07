# Implementation Plan: egui Popup for cctop-menubar

## Overview

Replace the native NSMenu in cctop-menubar with a custom egui popup window to match the "Minimal" design with colored status dots, hover effects, and better styling.

## Architecture

```
Current:  TrayIcon → Native NSMenu → MenuEvent
New:      TrayIcon → TrayIconEvent → Custom Window (egui) → Focus Terminal
```

## Phases

### Phase 1: Dependencies

Add to `Cargo.toml`:
```toml
[target.'cfg(target_os = "macos")'.dependencies]
egui = "0.29"
egui-wgpu = "0.29"
wgpu = "22.0"
raw-window-handle = "0.6"
```

### Phase 2: New Files

| File | Purpose |
|------|---------|
| `src/menubar/popup_state.rs` | State: visibility, position, sessions |
| `src/menubar/popup.rs` | egui UI rendering |

### Phase 3: Modify `cctop_menubar.rs`

1. Remove native Menu from TrayIconBuilder
2. Handle `TrayIconEvent::Click` to show/hide popup
3. Create borderless window for popup
4. Integrate egui-wgpu renderer
5. Handle session clicks → focus_terminal()

## UI Design (egui implementation)

```
┌─────────────────────────────────┐  288px wide
│  ● project-name                 │
│    feature/branch               │  Needs Attention (amber dot)
│  ● another-project              │
│    main                         │  Working (green dot)
├─────────────────────────────────┤
│  IDLE                           │  Section header
│  ○ docs-site                    │
│    main                         │  Idle (gray dot)
├─────────────────────────────────┤
│  Quit cctop                     │
└─────────────────────────────────┘
```

### Colors (matching Minimal design)
- Background: `rgb(31, 41, 55)` at 95% opacity
- Hover: `rgba(255, 255, 255, 0.1)`
- Text primary: white
- Text secondary: `rgb(156, 163, 175)`
- Status amber: `rgb(245, 158, 11)`
- Status green: `rgb(34, 197, 94)`
- Status gray: `rgb(156, 163, 175)`

## Event Handling

| Event | Action |
|-------|--------|
| Tray click (left) | Toggle popup visibility |
| Session row click | `focus_terminal()` + hide popup |
| Focus lost | Hide popup |
| "Quit" click | Exit app |
| ESC key | Hide popup |

## Implementation Order

1. Add egui dependencies
2. Create `popup_state.rs` (simple, testable)
3. Create `popup.rs` skeleton
4. Update `cctop_menubar.rs` with window creation
5. Add egui-wgpu rendering integration
6. Implement full popup UI with styling
7. Add click/hover event handling
8. Test and polish

## Challenges

1. **egui-wgpu + tao integration**: Need to create wgpu surface from tao window
2. **Window focus**: Popup should not steal focus (`with_focusable(false)`)
3. **Click-outside-to-close**: Rely on `Focused(false)` event
4. **Positioning**: Calculate popup position from tray icon rect

## Effort Estimate

| Task | Time |
|------|------|
| Dependencies + setup | 30m |
| popup_state.rs | 30m |
| popup.rs (basic) | 1h |
| egui-wgpu integration | 1-2h |
| Full UI styling | 1h |
| Event handling | 30m |
| Testing + polish | 1h |
| **Total** | **~5-6h** |

## References

- [tray-icon egui example](https://github.com/tauri-apps/tray-icon/blob/dev/examples/egui.rs)
- [egui documentation](https://docs.rs/egui/latest/egui/)
- [tauri-menubar-app](https://github.com/4gray/tauri-menubar-app)
