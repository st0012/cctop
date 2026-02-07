# Plan: macOS Menu Bar App

## Overview
Create a separate binary `cctop-menubar` that shows Claude Code sessions in the macOS menu bar.

## Architecture
```
src/
├── bin/
│   ├── cctop_hook.rs      # Existing hook binary
│   └── cctop_menubar.rs   # NEW: Menu bar binary
├── menubar/               # NEW: Menu bar module
│   ├── mod.rs
│   └── menu.rs            # Menu building logic
```

## Dependencies
```toml
[target.'cfg(target_os = "macos")'.dependencies]
tray-icon = "0.21"      # System tray/menu bar icon
tao = "0.34"            # Event loop for GUI apps

[dependencies]
notify = "7.0"          # File watching for session changes
```

## Implementation Outline

### 1. Menu Bar Binary (`src/bin/cctop_menubar.rs`)
```rust
use tray_icon::{TrayIconBuilder, Icon};
use tray_icon::menu::{Menu, MenuItem, PredefinedMenuItem};
use tao::event_loop::{ControlFlow, EventLoop};
use notify::{Watcher, RecommendedWatcher};

fn main() {
    // 1. Set up file watcher for ~/.cctop/sessions/
    // 2. Create event loop (required for macOS)
    // 3. Hide from Dock (Accessory activation policy)
    // 4. Build initial menu from sessions
    // 5. Create tray icon with menu
    // 6. Run event loop, handling:
    //    - Menu item clicks -> focus_terminal()
    //    - File system events -> rebuild menu
}
```

### 2. Menu Structure (Minimal Design)
```
┌────────────────────────────────────┐
│  ● api-server                      │  <- amber dot (pulsing)
│    feature/oauth                   │
│  ● frontend-app                    │  <- emerald dot
│    fix/login                       │
│  ● data-pipeline                   │  <- emerald dot
│    refactor                        │
├────────────────────────────────────┤
│  Idle                              │  <- section header
│  ● docs-site                       │  <- gray dot, dimmed
│    main                            │
│  ● infra-terraform                 │
│    feature/k8s                     │
├────────────────────────────────────┤
│  ⌨️ Open TUI                        │
│  ⚙️ Settings...                     │
│  ─────────────────────────────     │
│  Quit cctop                        │
└────────────────────────────────────┘
```

### 3. Key Features
- **Minimal Apple-style**: Clean design with subtle colored dots
- **Status indicators**:
  - Amber dot (pulsing) = needs attention
  - Emerald dot = working
  - Gray dot = idle (dimmed section)
- **Dynamic updates**: Watch `~/.cctop/sessions/` with notify crate
- **Click to focus**: Reuse `cctop::focus::focus_terminal()`
- **Hide Dock icon**: Use `ActivationPolicy::Accessory`

### 4. Challenges
| Challenge | Solution |
|-----------|----------|
| Main thread requirement | Create tray in event loop's Init handler |
| Dynamic menu updates | Rebuild menu on file change events |
| Auto-start on login | Optional: Create launchd plist |
| Cross-platform | Conditional compilation for macOS only |

## Files to Create/Modify
| File | Action |
|------|--------|
| `Cargo.toml` | Add tray-icon, tao, notify dependencies |
| `src/bin/cctop_menubar.rs` | Create: main menu bar binary |
| `src/menubar/mod.rs` | Create: menu bar module |
| `src/menubar/menu.rs` | Create: menu building logic |
| `src/lib.rs` | Export focus module for reuse |

## Verification
1. `cargo build --bin cctop-menubar`
2. Run `./target/debug/cctop-menubar`
3. Menu bar icon appears (no Dock icon)
4. Menu shows current sessions grouped by status
5. Click session -> terminal focuses
6. Create/modify session file -> menu updates
7. Click "Quit" -> app exits
