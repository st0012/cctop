//! cctop - Claude Code Session Monitor
//!
//! A TUI for monitoring Claude Code sessions across workspaces.
//!
//! Usage: cctop [OPTIONS]
//!
//! Options:
//!   --cleanup-stale  Run stale session cleanup and exit
//!   --print-config   Print the loaded configuration and exit
//!   -V, --version    Print version and exit
//!
//! Keyboard shortcuts:
//! - Up/Down or k/j: Navigate sessions
//! - Enter: Jump to the selected session's terminal
//! - r: Refresh session list
//! - q or Esc: Quit

use cctop::config::Config;
use cctop::session::{cleanup_stale_sessions, Session};
use cctop::tui::{init_terminal, restore_terminal, App};
use chrono::Duration;
use std::env;

fn main() {
    // Parse command line arguments
    let args: Vec<String> = env::args().collect();

    if let Some(arg) = args.get(1) {
        match arg.as_str() {
            "--version" | "-V" => {
                println!("cctop {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            "--print-config" => {
                let config = Config::load();
                println!("{:#?}", config);
                std::process::exit(0);
            }
            "--cleanup-stale" => {
                let sessions_dir = Config::sessions_dir();

                // Count sessions before cleanup
                let before_count = Session::load_all(&sessions_dir)
                    .map(|s| s.len())
                    .unwrap_or(0);

                // Run cleanup (24 hour max age)
                if let Err(e) = cleanup_stale_sessions(&sessions_dir, Duration::hours(24)) {
                    eprintln!("Error during cleanup: {}", e);
                    std::process::exit(1);
                }

                // Count sessions after cleanup
                let after_count = Session::load_all(&sessions_dir)
                    .map(|s| s.len())
                    .unwrap_or(0);

                let cleaned = before_count.saturating_sub(after_count);
                println!("Cleaned up {} stale session(s)", cleaned);
                std::process::exit(0);
            }
            _ => {
                eprintln!("Unknown argument: {}", arg);
                eprintln!("Usage: cctop [--cleanup-stale | --print-config | -V | --version]");
                std::process::exit(1);
            }
        }
    }

    // Load configuration
    let config = Config::load();

    // Initialize terminal
    let mut terminal = match init_terminal() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("Failed to initialize terminal: {}", e);
            std::process::exit(1);
        }
    };

    // Create and run the app
    let mut app = App::new(config);
    let result = app.run(&mut terminal);

    // Restore terminal state before handling any errors
    if let Err(e) = restore_terminal() {
        eprintln!("Failed to restore terminal: {}", e);
    }

    // Handle any errors from the app
    if let Err(e) = result {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}
