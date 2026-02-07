//! cctop - Claude Code Session Monitor
//!
//! A TUI for monitoring Claude Code sessions across workspaces.
//!
//! Usage: cctop [OPTIONS]
//!
//! Options:
//!   -l, --list       List sessions as text and exit (no TUI)
//!   --cleanup-stale  Run stale session cleanup and exit
//!   --print-config   Print the loaded configuration and exit
//!
//! Environment variables:
//!   CCTOP_DEMO=1     Skip session liveness checks (for demos with mock data)
//!   -V, --version    Print version and exit
//!
//! Keyboard shortcuts:
//! - Up/Down or k/j: Navigate sessions
//! - Enter: Jump to the selected session's terminal
//! - r: Refresh session list
//! - q or Esc: Quit

use cctop::config::Config;
use cctop::session::{cleanup_stale_sessions, format_relative_time, Session, Status};
use cctop::tui::{init_terminal, restore_terminal, App};
use chrono::Duration;
use std::env;

fn main() {
    // Parse command line arguments
    let args: Vec<String> = env::args().collect();

    // Check for demo mode via environment variable
    let demo_mode = env::var("CCTOP_DEMO").map(|v| v == "1").unwrap_or(false);

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
            "--list" | "-l" => {
                list_sessions();
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
                eprintln!("Usage: cctop [-l | --list | --cleanup-stale | --print-config | -V | --version]");
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
    let mut app = App::new(config).with_demo_mode(demo_mode);
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

/// List sessions as text output (non-TUI mode).
fn list_sessions() {
    let sessions_dir = Config::sessions_dir();
    let mut sessions = match Session::load_all(&sessions_dir) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Failed to load sessions: {}", e);
            return;
        }
    };

    // Filter out dead sessions
    sessions.retain(|s| is_session_alive(&s.project_path));

    if sessions.is_empty() {
        println!("No active sessions");
        return;
    }

    // Sort by status priority, then by last_activity
    sessions.sort_by(|a, b| {
        let priority = |s: &Status| match s {
            Status::WaitingPermission => 0,
            Status::WaitingInput | Status::NeedsAttention => 1,
            Status::Working => 2,
            Status::Idle => 3,
        };
        priority(&a.status)
            .cmp(&priority(&b.status))
            .then_with(|| b.last_activity.cmp(&a.last_activity))
    });

    println!("{} session(s):\n", sessions.len());

    for session in &sessions {
        let status = match session.status {
            Status::WaitingPermission => "WAITING_PERMISSION",
            Status::WaitingInput | Status::NeedsAttention => "WAITING_INPUT",
            Status::Working => "WORKING",
            Status::Idle => "IDLE",
        };

        let time_ago = format_relative_time(session.last_activity);

        println!(
            "[{}] {} ({}) - {}",
            status, session.project_name, session.branch, time_ago
        );

        if let Some(prompt) = &session.last_prompt {
            let truncated = if prompt.len() > 60 {
                format!("{}...", &prompt[..57])
            } else {
                prompt.clone()
            };
            println!("  \"{}\"", truncated);
        }
    }
}

/// Check if a session is still alive by verifying a claude process is running in that directory.
fn is_session_alive(project_path: &str) -> bool {
    use std::process::Command;

    // Use ps + lsof to find any process with claude in its command line that has this cwd
    // First get PIDs of claude processes, then check their cwd
    let output = Command::new("sh")
        .arg("-c")
        .arg(format!(
            "ps aux | grep -E 'claude|Claude' | grep -v grep | awk '{{print $2}}' | while read pid; do lsof -p $pid 2>/dev/null | grep cwd | grep -q '{}' && echo found; done",
            project_path
        ))
        .output();

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            stdout.contains("found")
        }
        Err(_) => true,
    }
}
