//! macOS menubar application for cctop with egui popup.
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
    if let Err(e) = cctop::menubar::app::MenubarApp::run() {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}
