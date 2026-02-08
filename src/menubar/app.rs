//! Main application logic for the menubar popup.

use crate::config::Config;
use crate::focus::focus_terminal;
use crate::menubar::popup::{calculate_popup_height, render_popup, POPUP_WIDTH, QUIT_ACTION};
use crate::menubar::popup_state::PopupState;
use crate::menubar::renderer::Renderer;
use crate::session::{load_live_sessions, Session};
use crate::watcher::SessionWatcher;
use anyhow::{Context, Result};
use std::cell::RefCell;
use std::time::{Duration, Instant};
use tao::dpi::{LogicalPosition, LogicalSize};
use tao::event::{Event, StartCause, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoop};
use tao::platform::macos::{ActivationPolicy, EventLoopExtMacOS};
use tao::window::{Window, WindowBuilder};
use tray_icon::{TrayIcon, TrayIconBuilder};

/// Install symlinks for bundled binaries into `~/.local/bin/`.
///
/// This allows .app-only users (who didn't `cargo install`) to use cctop-hook
/// (for Claude Code hooks) and cctop (TUI) from the command line.
/// Skips each binary if it already exists in `~/.cargo/bin/` (cargo install users).
fn install_bundled_binaries() {
    use std::fs;
    use std::os::unix::fs as unix_fs;

    let Ok(exe_path) = std::env::current_exe() else {
        return;
    };
    let Some(exe_dir) = exe_path.parent() else {
        return;
    };
    let Some(home) = dirs::home_dir() else {
        return;
    };

    let cargo_bin = home.join(".cargo").join("bin");
    let local_bin = home.join(".local").join("bin");

    for binary_name in &["cctop-hook", "cctop"] {
        let binary_in_bundle = exe_dir.join(binary_name);
        if !binary_in_bundle.exists() {
            continue;
        }

        // Skip if cargo install version already exists
        if cargo_bin.join(binary_name).exists() {
            continue;
        }

        // Create ~/.local/bin/ if needed
        if let Err(e) = fs::create_dir_all(&local_bin) {
            eprintln!("[cctop-menubar] Failed to create ~/.local/bin: {}", e);
            return;
        }

        let symlink_path = local_bin.join(binary_name);

        // Check if symlink already points to the right place
        if symlink_path.exists() || symlink_path.symlink_metadata().is_ok() {
            if let Ok(target) = fs::read_link(&symlink_path) {
                if target == binary_in_bundle {
                    continue; // Already correct
                }
            }
            let _ = fs::remove_file(&symlink_path);
        }

        match unix_fs::symlink(&binary_in_bundle, &symlink_path) {
            Ok(()) => {
                eprintln!(
                    "[cctop-menubar] Installed {} symlink: {} -> {}",
                    binary_name,
                    symlink_path.display(),
                    binary_in_bundle.display()
                );
            }
            Err(e) => {
                eprintln!(
                    "[cctop-menubar] Failed to create symlink at {}: {}",
                    symlink_path.display(),
                    e
                );
            }
        }
    }
}

/// Compute the tray title based on session states.
///
/// Returns "CC" when no sessions need attention,
/// or "CC (N)" when N sessions need attention.
fn tray_title(sessions: &[Session]) -> String {
    let attention_count = sessions
        .iter()
        .filter(|s| s.status.needs_attention())
        .count();
    if attention_count > 0 {
        format!("CC ({})", attention_count)
    } else {
        "CC".to_string()
    }
}

/// Update the tray icon title based on current sessions.
fn update_tray_title(tray_icon: &TrayIcon, sessions: &[Session]) {
    let title = tray_title(sessions);
    tray_icon.set_title(Some(&title));
}

/// Calculate popup position in logical coordinates from tray icon rect.
///
/// `tray_icon::Rect` returns physical pixel coordinates. We convert to logical
/// points so the centering math is consistent with `POPUP_WIDTH` (also logical).
fn calculate_popup_position(rect: &tray_icon::Rect, scale_factor: f64) -> (f64, f64) {
    let x = rect.position.x / scale_factor;
    let y = rect.position.y / scale_factor + rect.size.height as f64 / scale_factor;
    let icon_w = rect.size.width as f64 / scale_factor;
    let popup_x = x - (POPUP_WIDTH as f64 / 2.0) + (icon_w / 2.0);
    let popup_y = y + 4.0;
    (popup_x, popup_y)
}

/// Main menubar application.
pub struct MenubarApp {
    window: Window,
    renderer: Renderer,
    popup_state: PopupState,
    sessions: Vec<Session>,
    watcher: Option<SessionWatcher>,
    config: Config,
    sessions_dir: std::path::PathBuf,
    cursor_pos: egui::Pos2,
    egui_input: egui::RawInput,
    /// When egui requests a future repaint (e.g. for animations), we schedule
    /// a window redraw at this instant.
    next_repaint: Option<Instant>,
}

impl MenubarApp {
    /// Run the menubar application.
    pub fn run() -> Result<()> {
        eprintln!("[cctop-menubar] Starting...");

        // Install symlinks for bundled binaries (.app-only users)
        install_bundled_binaries();

        // Get sessions directory
        let sessions_dir = dirs::home_dir()
            .context("Could not determine home directory")?
            .join(".cctop")
            .join("sessions");

        // Load initial sessions
        let sessions = load_live_sessions(&sessions_dir).unwrap_or_default();

        // Load config
        let config = Config::load();

        // Create event loop with Accessory policy (no dock icon)
        let mut event_loop: EventLoop<()> = EventLoop::new();
        event_loop.set_activation_policy(ActivationPolicy::Accessory);

        // Calculate initial popup size
        let popup_height = calculate_popup_height(&sessions);

        // Create the popup window (initially hidden, transparent for arrow effect)
        let window = WindowBuilder::new()
            .with_title("cctop")
            .with_inner_size(LogicalSize::new(POPUP_WIDTH as f64, popup_height as f64))
            .with_decorations(false)
            .with_resizable(false)
            .with_visible(false)
            .with_always_on_top(true)
            .with_transparent(true)
            .build(&event_loop)
            .context("Failed to create popup window")?;

        window.set_always_on_top(true);

        // Create renderer
        let renderer = Renderer::new(&window)?;

        // Initialize egui input
        let mut egui_input = renderer.create_input();
        egui_input.screen_rect = Some(egui::Rect::from_min_size(
            egui::Pos2::ZERO,
            egui::vec2(POPUP_WIDTH, popup_height),
        ));

        // Create app state
        let app = RefCell::new(Self {
            window,
            renderer,
            popup_state: PopupState::new(),
            sessions,
            watcher: SessionWatcher::new().ok(),
            config,
            sessions_dir,
            cursor_pos: egui::pos2(0.0, 0.0),
            egui_input,
            next_repaint: None,
        });

        // Warmup render
        {
            let mut app = app.borrow_mut();
            let sessions_clone = app.sessions.clone();
            let _ = app.renderer.warmup(|ctx| {
                render_popup(ctx, &sessions_clone);
            });
        }

        // Create tray icon with initial title based on loaded sessions
        let initial_title = tray_title(&app.borrow().sessions);
        let tray_icon = TrayIconBuilder::new()
            .with_tooltip("cctop - Claude Code Sessions")
            .with_title(&initial_title)
            .build()
            .context("Failed to create tray icon")?;

        let tray_icon = RefCell::new(tray_icon);

        // Run event loop
        event_loop.run(move |event, _event_loop, control_flow| {
            // Use a shorter polling interval when an animation repaint is pending,
            // otherwise fall back to the default 100ms session-polling interval.
            let poll_interval = if app.borrow().next_repaint.is_some() {
                Duration::from_millis(16) // ~60fps for smooth animation
            } else {
                Duration::from_millis(100) // session polling
            };
            *control_flow = ControlFlow::WaitUntil(Instant::now() + poll_interval);

            // Handle tray icon events
            while let Ok(tray_event) = tray_icon::TrayIconEvent::receiver().try_recv() {
                if let tray_icon::TrayIconEvent::Click {
                    button_state: tray_icon::MouseButtonState::Up,
                    ..
                } = tray_event
                {
                    let mut app = app.borrow_mut();
                    if let Some(rect) = tray_icon.borrow().rect() {
                        app.handle_tray_click(rect);
                    }
                }
            }

            // Handle window events
            match event {
                Event::NewEvents(StartCause::ResumeTimeReached { .. }) => {
                    let changed = app.borrow_mut().poll_session_changes();
                    if changed {
                        update_tray_title(&tray_icon.borrow(), &app.borrow().sessions);
                    }

                    // Check if egui scheduled an animation repaint
                    let mut app = app.borrow_mut();
                    if let Some(repaint_at) = app.next_repaint {
                        if Instant::now() >= repaint_at && app.popup_state.visible {
                            app.next_repaint = None;
                            app.window.request_redraw();
                        }
                    }
                }

                Event::WindowEvent {
                    event: WindowEvent::CloseRequested,
                    ..
                } => {
                    *control_flow = ControlFlow::Exit;
                }

                Event::WindowEvent {
                    event: WindowEvent::Resized(new_size),
                    ..
                } => {
                    let mut app = app.borrow_mut();
                    app.handle_resize(new_size.width, new_size.height);
                }

                Event::WindowEvent {
                    event: WindowEvent::ScaleFactorChanged { scale_factor, .. },
                    ..
                } => {
                    let mut app = app.borrow_mut();
                    app.handle_scale_factor_change(scale_factor);
                }

                Event::WindowEvent {
                    event: WindowEvent::CursorMoved { position, .. },
                    ..
                } => {
                    let mut app = app.borrow_mut();
                    app.handle_cursor_move(position.x, position.y);
                }

                Event::WindowEvent {
                    event: WindowEvent::MouseInput { state, button, .. },
                    ..
                } => {
                    let mut app = app.borrow_mut();
                    app.handle_mouse_input(state, button);
                }

                #[allow(deprecated)]
                Event::WindowEvent {
                    event: WindowEvent::MouseWheel { delta, .. },
                    ..
                } => {
                    let mut app = app.borrow_mut();
                    app.handle_mouse_wheel(delta);
                }

                Event::WindowEvent {
                    event:
                        WindowEvent::KeyboardInput {
                            event:
                                tao::event::KeyEvent {
                                    physical_key: tao::keyboard::KeyCode::Escape,
                                    state: tao::event::ElementState::Pressed,
                                    ..
                                },
                            ..
                        },
                    ..
                } => {
                    app.borrow_mut().hide_popup();
                }

                Event::WindowEvent {
                    event: WindowEvent::Focused(false),
                    ..
                } => {
                    let mut app = app.borrow_mut();
                    // Debounce: don't dismiss if popup was just shown (<200ms ago).
                    // This prevents a race where clicking the tray icon fires
                    // Focused(false) on the old popup before the new show completes.
                    if app.popup_state.visible
                        && app.popup_state.visible_duration() > Duration::from_millis(200)
                    {
                        app.hide_popup();
                    }
                }

                Event::RedrawRequested(_) => {
                    let mut app = app.borrow_mut();
                    if let Some(action) = app.redraw() {
                        if action == QUIT_ACTION {
                            *control_flow = ControlFlow::Exit;
                        }
                    }
                }

                _ => {}
            }
        });
    }

    fn handle_tray_click(&mut self, rect: tray_icon::Rect) {
        let scale = self.window.scale_factor();
        let (popup_x, popup_y) = calculate_popup_position(&rect, scale);

        if self.popup_state.visible {
            self.hide_popup();
        } else {
            let popup_height = calculate_popup_height(&self.sessions);

            // Position and resize window (still hidden)
            self.window
                .set_outer_position(LogicalPosition::new(popup_x, popup_y));
            self.window
                .set_inner_size(LogicalSize::new(POPUP_WIDTH as f64, popup_height as f64));

            // Use calculated size directly - don't query window as set_inner_size is async
            let scale_factor = self.renderer.scale_factor();
            let physical_width = (POPUP_WIDTH as f64 * scale_factor) as u32;
            let physical_height = (popup_height as f64 * scale_factor) as u32;

            // Update renderer for new size (this also resets layer opacity)
            self.renderer.resize(physical_width, physical_height);

            // Update egui input for new size
            self.egui_input.screen_rect = Some(egui::Rect::from_min_size(
                egui::Pos2::ZERO,
                egui::vec2(POPUP_WIDTH, popup_height),
            ));

            // Pre-render while hidden to ensure the first visible frame is correct
            self.popup_state.show();
            for _ in 0..2 {
                let input = self.renderer.create_input();
                let sessions = &self.sessions;
                let _ = self
                    .renderer
                    .render(input, |ctx| render_popup(ctx, sessions));
            }
            self.egui_input = self.renderer.create_input();

            // Now show the window with pre-rendered content
            self.window.set_visible(true);
        }
    }

    fn hide_popup(&mut self) {
        self.popup_state.hide();
        self.window.set_visible(false);
    }

    fn poll_session_changes(&mut self) -> bool {
        if let Some(ref mut watcher) = self.watcher {
            if let Some(new_sessions) = watcher.poll_changes() {
                self.sessions = new_sessions;

                if self.popup_state.visible {
                    let popup_height = calculate_popup_height(&self.sessions);
                    self.window
                        .set_inner_size(LogicalSize::new(POPUP_WIDTH as f64, popup_height as f64));
                    self.window.request_redraw();
                }
                return true;
            }
        }
        false
    }

    fn handle_resize(&mut self, width: u32, height: u32) {
        self.renderer.resize(width, height);

        let scale_factor = self.renderer.scale_factor();
        let logical_width = width as f32 / scale_factor as f32;
        let logical_height = height as f32 / scale_factor as f32;
        self.egui_input.screen_rect = Some(egui::Rect::from_min_size(
            egui::Pos2::ZERO,
            egui::vec2(logical_width, logical_height),
        ));
    }

    fn handle_scale_factor_change(&mut self, scale_factor: f64) {
        self.renderer.set_scale_factor(scale_factor);

        let size = self.window.inner_size();
        self.renderer.resize(size.width, size.height);

        let logical_width = size.width as f32 / scale_factor as f32;
        let logical_height = size.height as f32 / scale_factor as f32;
        self.egui_input.screen_rect = Some(egui::Rect::from_min_size(
            egui::Pos2::ZERO,
            egui::vec2(logical_width, logical_height),
        ));
    }

    fn handle_cursor_move(&mut self, x: f64, y: f64) {
        let scale_factor = self.renderer.scale_factor();
        let pos = egui::pos2(
            x as f32 / scale_factor as f32,
            y as f32 / scale_factor as f32,
        );
        self.cursor_pos = pos;
        self.egui_input.events.push(egui::Event::PointerMoved(pos));

        if self.popup_state.visible {
            self.window.request_redraw();
        }
    }

    fn handle_mouse_input(
        &mut self,
        state: tao::event::ElementState,
        button: tao::event::MouseButton,
    ) {
        let egui_button = match button {
            tao::event::MouseButton::Left => egui::PointerButton::Primary,
            tao::event::MouseButton::Right => egui::PointerButton::Secondary,
            tao::event::MouseButton::Middle => egui::PointerButton::Middle,
            _ => egui::PointerButton::Primary,
        };

        self.egui_input.events.push(egui::Event::PointerButton {
            pos: self.cursor_pos,
            button: egui_button,
            pressed: state == tao::event::ElementState::Pressed,
            modifiers: egui::Modifiers::default(),
        });

        if self.popup_state.visible {
            self.window.request_redraw();
        }
    }

    fn handle_mouse_wheel(&mut self, delta: tao::event::MouseScrollDelta) {
        use tao::event::MouseScrollDelta;

        let (unit, delta) = match delta {
            MouseScrollDelta::LineDelta(x, y) => (egui::MouseWheelUnit::Line, egui::vec2(x, y)),
            MouseScrollDelta::PixelDelta(pos) => {
                let scale_factor = self.renderer.scale_factor();
                (
                    egui::MouseWheelUnit::Point,
                    egui::vec2(
                        pos.x as f32 / scale_factor as f32,
                        pos.y as f32 / scale_factor as f32,
                    ),
                )
            }
            _ => return,
        };

        self.egui_input.events.push(egui::Event::MouseWheel {
            unit,
            delta,
            modifiers: egui::Modifiers::default(),
        });

        if self.popup_state.visible {
            self.window.request_redraw();
        }
    }

    fn redraw(&mut self) -> Option<String> {
        if !self.popup_state.visible {
            return None;
        }

        let input = std::mem::replace(&mut self.egui_input, self.renderer.create_input());
        let sessions = &self.sessions;
        let sessions_dir = self.sessions_dir.clone();
        let config = &self.config;

        let result = self
            .renderer
            .render(input, |ctx| render_popup(ctx, sessions));

        match result {
            Ok((Some(action), _repaint_after)) => {
                if action == QUIT_ACTION {
                    return Some(action);
                }

                // Find and focus the session
                if let Ok(all_sessions) = Session::load_all(&sessions_dir) {
                    if let Some(session) = all_sessions.iter().find(|s| s.session_id == action) {
                        if let Err(e) = focus_terminal(session, config) {
                            eprintln!("Failed to focus terminal: {}", e);
                        }
                    }
                }

                self.hide_popup();
                None
            }
            Ok((None, repaint_after)) => {
                // Schedule a future repaint if egui requested one (for animations)
                if repaint_after < Duration::from_secs(1) {
                    self.next_repaint = Some(Instant::now() + repaint_after);
                }
                None
            }
            Err(e) => {
                eprintln!("Render error: {}", e);
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tao::dpi::{PhysicalPosition, PhysicalSize};

    fn make_tray_rect(phys_x: f64, phys_y: f64, phys_w: u32, phys_h: u32) -> tray_icon::Rect {
        tray_icon::Rect {
            position: PhysicalPosition::new(phys_x, phys_y),
            size: PhysicalSize::new(phys_w, phys_h),
        }
    }

    #[test]
    fn test_popup_centered_on_tray_icon_retina() {
        // Retina display: scale_factor = 2.0
        // Tray icon at physical (1240, 0), size 64x48 physical
        // Logical: icon at (620, 0), size 32x24
        let rect = make_tray_rect(1240.0, 0.0, 64, 48);
        let (popup_x, popup_y) = calculate_popup_position(&rect, 2.0);

        // Popup should be centered on icon: icon_center_x - popup_width/2
        let icon_logical_x = 620.0;
        let icon_logical_w = 32.0;
        let expected_x = icon_logical_x - (POPUP_WIDTH as f64 / 2.0) + (icon_logical_w / 2.0);
        assert!(
            (popup_x - expected_x).abs() < 0.01,
            "popup_x={popup_x}, expected={expected_x}"
        );

        // Y should be below icon + 4pt gap
        let expected_y = 24.0 + 4.0; // icon bottom (24) + gap (4)
        assert!(
            (popup_y - expected_y).abs() < 0.01,
            "popup_y={popup_y}, expected={expected_y}"
        );
    }

    #[test]
    fn test_popup_centered_on_tray_icon_non_retina() {
        // Non-retina: scale_factor = 1.0
        // Physical = logical, icon at (620, 0), size 32x24
        let rect = make_tray_rect(620.0, 0.0, 32, 24);
        let (popup_x, popup_y) = calculate_popup_position(&rect, 1.0);

        let expected_x = 620.0 - (POPUP_WIDTH as f64 / 2.0) + 16.0;
        assert!(
            (popup_x - expected_x).abs() < 0.01,
            "popup_x={popup_x}, expected={expected_x}"
        );
        assert!((popup_y - 28.0).abs() < 0.01);
    }

    #[test]
    fn test_popup_position_scales_consistently() {
        // Same logical position, different scale factors should give same result
        let rect_1x = make_tray_rect(620.0, 0.0, 32, 24);
        let rect_2x = make_tray_rect(1240.0, 0.0, 64, 48);

        let (x_1x, y_1x) = calculate_popup_position(&rect_1x, 1.0);
        let (x_2x, y_2x) = calculate_popup_position(&rect_2x, 2.0);

        assert!(
            (x_1x - x_2x).abs() < 0.01,
            "1x={x_1x}, 2x={x_2x} should match"
        );
        assert!(
            (y_1x - y_2x).abs() < 0.01,
            "1x={y_1x}, 2x={y_2x} should match"
        );
    }
}
