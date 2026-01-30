//! macOS menubar application for cctop.
//!
//! Displays Claude Code session status in the system menu bar.
//! Click on a session to focus its terminal window.

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("cctop-menubar is only supported on macOS");
    std::process::exit(1);
}

#[cfg(target_os = "macos")]
fn main() {
    if let Err(e) = run_menubar() {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}

#[cfg(target_os = "macos")]
fn run_menubar() -> anyhow::Result<()> {
    use anyhow::Context;
    use cctop::config::Config;
    use cctop::focus::focus_terminal;
    use cctop::menubar::menu::{build_menu, ids};
    use cctop::session::Session;
    use cctop::watcher::SessionWatcher;
    use tao::event::{Event, StartCause};
    use tao::event_loop::{ControlFlow, EventLoop};
    use tao::platform::macos::{ActivationPolicy, EventLoopExtMacOS};
    use tray_icon::TrayIconBuilder;

    eprintln!("[cctop-menubar] Starting...");

    // Get sessions directory
    let sessions_dir = dirs::home_dir()
        .context("Could not determine home directory")?
        .join(".cctop")
        .join("sessions");

    eprintln!("[cctop-menubar] Sessions dir: {:?}", sessions_dir);

    // Load initial sessions
    let sessions = Session::load_all(&sessions_dir).unwrap_or_default();
    eprintln!("[cctop-menubar] Loaded {} sessions", sessions.len());

    // Load config for focus_terminal
    let config = Config::load();

    // Create event loop with Accessory policy (no dock icon, menu bar only)
    eprintln!("[cctop-menubar] Creating event loop...");
    let mut event_loop = EventLoop::new();
    event_loop.set_activation_policy(ActivationPolicy::Accessory);

    // Build initial menu
    eprintln!("[cctop-menubar] Building menu...");
    let menu = build_menu(&sessions);

    // Create tray icon with CC monogram title (no icon needed)
    eprintln!("[cctop-menubar] Creating tray icon...");
    let tray_icon = TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_tooltip("cctop - Claude Code Sessions")
        .with_title("CC") // CC monogram shown in menu bar
        .build()
        .context("Failed to create tray icon")?;

    eprintln!("[cctop-menubar] Tray icon created, entering event loop...");

    // Store sessions and watcher in RefCell for mutation in event loop
    let sessions = std::cell::RefCell::new(sessions);
    let watcher = std::cell::RefCell::new(SessionWatcher::new().ok());
    let tray_icon = std::cell::RefCell::new(tray_icon);

    // Run event loop
    event_loop.run(move |event, _, control_flow| {
        // Poll every 500ms for file changes
        *control_flow = ControlFlow::WaitUntil(
            std::time::Instant::now() + std::time::Duration::from_millis(500),
        );

        match event {
            Event::NewEvents(StartCause::Init) => {
                // App just started
            }
            Event::NewEvents(StartCause::ResumeTimeReached { .. }) => {
                // Check for file changes
                if let Some(ref mut w) = *watcher.borrow_mut() {
                    if let Some(new_sessions) = w.poll_changes() {
                        // Update stored sessions
                        *sessions.borrow_mut() = new_sessions;

                        // Rebuild and update menu
                        let new_menu = build_menu(&sessions.borrow());
                        tray_icon.borrow().set_menu(Some(Box::new(new_menu)));
                    }
                }
            }
            _ => {}
        }

        // Handle menu events
        if let Ok(event) = tray_icon::menu::MenuEvent::receiver().try_recv() {
            let id = event.id.0.as_str();

            if id == ids::QUIT {
                *control_flow = ControlFlow::Exit;
            } else if let Some(session_id) = id.strip_prefix(ids::SESSION_PREFIX) {
                // Find the session and focus it
                let sessions = sessions.borrow();
                if let Some(session) = sessions.iter().find(|s| s.session_id == session_id) {
                    if let Err(e) = focus_terminal(session, &config) {
                        eprintln!("Failed to focus terminal: {}", e);
                    }
                }
            }
        }
    });
}
