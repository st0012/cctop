//! cctop - Claude Code Session Monitor
//!
//! A TUI for monitoring Claude Code sessions across workspaces.

use cctop::config::Config;
use cctop::session::{
    cleanup_stale_sessions, format_relative_time, generate_dot_diagram, load_live_sessions,
    truncate_prompt, Session,
};
use cctop::tui::{init_terminal, restore_terminal, App};
use chrono::Duration;
use clap::Parser;

/// TUI for monitoring Claude Code sessions across workspaces.
#[derive(Parser)]
#[command(
    name = "cctop",
    version,
    about,
    long_about = "\
TUI for monitoring Claude Code sessions across workspaces.\n\n\
Run without arguments to launch the interactive TUI.\n\n\
Keyboard shortcuts (TUI mode):\n  \
Up/Down or k/j    Navigate sessions\n  \
Right/Left or l/h Detail/back view\n  \
Enter             Jump to session's terminal\n  \
r                 Refresh session list\n  \
R                 Reset selected session to idle\n  \
q or Esc          Quit\n\n\
Environment variables:\n  \
CCTOP_DEMO=1      Skip session liveness checks (for demos)"
)]
struct Cli {
    /// List sessions as text and exit (no TUI)
    #[arg(short, long)]
    list: bool,

    /// Reset a session's status to idle (by session ID prefix)
    #[arg(long, value_name = "SESSION_ID")]
    reset: Option<String>,

    /// Print state machine as Graphviz DOT diagram and exit
    #[arg(long)]
    dot: bool,

    /// Run stale session cleanup and exit
    #[arg(long)]
    cleanup_stale: bool,

    /// Print the loaded configuration and exit
    #[arg(long)]
    print_config: bool,

    /// Check hook delivery chain health and exit
    #[arg(long)]
    check: bool,
}

fn main() {
    let cli = Cli::parse();

    // Check for demo mode via environment variable
    let demo_mode = std::env::var("CCTOP_DEMO")
        .map(|v| v == "1")
        .unwrap_or(false);

    if cli.check {
        run_health_check();
        return;
    }

    if cli.print_config {
        let config = Config::load();
        println!("{:#?}", config);
        return;
    }

    if cli.list {
        list_sessions();
        return;
    }

    if cli.cleanup_stale {
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
        return;
    }

    if cli.dot {
        println!("{}", generate_dot_diagram());
        return;
    }

    if let Some(id_prefix) = cli.reset {
        reset_session(&id_prefix);
        return;
    }

    // Default: launch the TUI

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
    let mut sessions = match load_live_sessions(&sessions_dir) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Failed to load sessions: {}", e);
            return;
        }
    };

    if sessions.is_empty() {
        println!("No active sessions");
        return;
    }

    // Sort by status priority, then by last_activity
    sessions.sort_by(|a, b| {
        a.status
            .sort_priority()
            .cmp(&b.status.sort_priority())
            .then_with(|| b.last_activity.cmp(&a.last_activity))
    });

    println!("{} session(s):\n", sessions.len());

    for session in &sessions {
        let status = session.status.as_str().to_uppercase();
        let time_ago = format_relative_time(session.last_activity);
        let id_prefix = &session.session_id[..session.session_id.len().min(8)];

        println!(
            "[{}] {} ({}) - {}  id:{}",
            status, session.project_name, session.branch, time_ago, id_prefix
        );

        if let Some(prompt) = &session.last_prompt {
            println!("  \"{}\"", truncate_prompt(prompt, 60));
        }
    }
}

/// Reset a session's status to idle by session ID prefix.
fn reset_session(id_prefix: &str) {
    let sessions_dir = Config::sessions_dir();
    let sessions = match Session::load_all(&sessions_dir) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Failed to load sessions: {}", e);
            std::process::exit(1);
        }
    };

    let matches: Vec<&Session> = sessions
        .iter()
        .filter(|s| s.session_id.starts_with(id_prefix))
        .collect();

    match matches.len() {
        0 => {
            eprintln!("No session found matching \"{}\"", id_prefix);
            std::process::exit(1);
        }
        1 => {
            let session = matches[0];
            let path = session.file_path(&sessions_dir);
            match Session::from_file(&path) {
                Ok(mut fresh) => {
                    fresh.reset();
                    if let Err(e) = fresh.write_to_file(&path) {
                        eprintln!("Failed to write session: {}", e);
                        std::process::exit(1);
                    }
                    println!("Reset \"{}\" to idle", session.project_name);
                }
                Err(e) => {
                    eprintln!("Failed to read session: {}", e);
                    std::process::exit(1);
                }
            }
        }
        n => {
            eprintln!(
                "Ambiguous prefix \"{}\": matches {} sessions. Be more specific.",
                id_prefix, n
            );
            for s in matches {
                eprintln!(
                    "  {} ({})",
                    &s.session_id[..s.session_id.len().min(12)],
                    s.project_name
                );
            }
            std::process::exit(1);
        }
    }
}

/// Run health checks on the hook delivery chain.
fn run_health_check() {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;

    let home = dirs::home_dir().unwrap_or_default();
    let mut all_ok = true;

    // 1. Check cctop-hook binary (same search order as run-hook.sh)
    let hook_paths = [
        home.join(".cargo/bin/cctop-hook"),
        home.join(".local/bin/cctop-hook"),
        PathBuf::from("/Applications/cctop.app/Contents/MacOS/cctop-hook"),
        home.join("Applications/cctop.app/Contents/MacOS/cctop-hook"),
        PathBuf::from("/opt/homebrew/bin/cctop-hook"),
        PathBuf::from("/usr/local/bin/cctop-hook"),
    ];
    let found_hook = hook_paths.iter().find(|p| p.is_file());
    match found_hook {
        Some(path) => {
            let executable = fs::metadata(path)
                .map(|m| m.permissions().mode() & 0o111 != 0)
                .unwrap_or(false);
            if executable {
                println!("cctop-hook binary    OK  ({})", path.display());
            } else {
                println!(
                    "cctop-hook binary    FAIL  (found {} but not executable)",
                    path.display()
                );
                all_ok = false;
            }
        }
        None => {
            // Fall back to PATH check
            let in_path = std::process::Command::new("which")
                .arg("cctop-hook")
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false);
            if in_path {
                println!("cctop-hook binary    OK  (found in PATH)");
            } else {
                println!("cctop-hook binary    FAIL  (not found in any expected location)");
                println!("                     hint: install the app to /Applications/ or run: cargo install cctop");
                all_ok = false;
            }
        }
    }

    // 2. Check plugin marketplace (stored in known_marketplaces.json)
    let known_marketplaces = home.join(".claude/plugins/known_marketplaces.json");
    let marketplace_found = fs::read_to_string(&known_marketplaces)
        .map(|c| c.contains("\"cctop\""))
        .unwrap_or(false);
    if marketplace_found {
        println!("Plugin marketplace    OK");
    } else {
        println!("Plugin marketplace    FAIL  (cctop marketplace not found)");
        println!("                     hint: run: claude plugin marketplace add st0012/cctop");
        all_ok = false;
    }

    // 3. Check plugin installed (ground truth: installed_plugins.json)
    let installed_plugins = home.join(".claude/plugins/installed_plugins.json");
    let plugin_installed = fs::read_to_string(&installed_plugins)
        .map(|c| c.contains("\"cctop@cctop\""))
        .unwrap_or(false);
    if plugin_installed {
        println!("Plugin installed      OK");
    } else {
        println!("Plugin installed      FAIL  (cctop not found in installed plugins)");
        println!("                     hint: run: claude plugin install cctop");
        all_ok = false;
    }

    // 4. Check sessions directory
    let sessions_dir = Config::sessions_dir();
    if sessions_dir.is_dir() {
        let test_file = sessions_dir.join(".write-test");
        if fs::write(&test_file, "").is_ok() {
            let _ = fs::remove_file(&test_file);
            println!("Sessions directory    OK  ({})", sessions_dir.display());
        } else {
            println!(
                "Sessions directory    FAIL  ({} exists but not writable)",
                sessions_dir.display()
            );
            all_ok = false;
        }
    } else {
        println!(
            "Sessions directory    FAIL  ({} does not exist)",
            sessions_dir.display()
        );
        all_ok = false;
    }

    // 5. Check recent hook activity
    let logs_dir = home.join(".cctop/logs");
    let recent_activity = if logs_dir.is_dir() {
        fs::read_dir(&logs_dir)
            .ok()
            .and_then(|entries| {
                entries
                    .flatten()
                    .filter(|e| {
                        let name = e.file_name();
                        let name = name.to_string_lossy();
                        name.ends_with(".log") && !name.starts_with('_')
                    })
                    .filter_map(|e| e.metadata().ok().and_then(|m| m.modified().ok()))
                    .max()
            })
            .and_then(|latest| latest.elapsed().ok())
    } else {
        None
    };
    match recent_activity {
        Some(elapsed) if elapsed.as_secs() < 300 => {
            let secs = elapsed.as_secs();
            println!("Recent hook activity OK  ({}s ago)", secs);
        }
        Some(elapsed) => {
            let mins = elapsed.as_secs() / 60;
            println!("Recent hook activity WARN  (last activity {}m ago)", mins);
            println!(
                "                     hint: start a Claude Code session to generate hook events"
            );
        }
        None => {
            println!("Recent hook activity WARN  (no hook logs found)");
            println!(
                "                     hint: start a Claude Code session to generate hook events"
            );
        }
    }

    // Summary
    println!();
    if all_ok {
        println!("All checks passed.");
    } else {
        println!("Some checks failed. Fix the issues above and re-run: cctop --check");
        std::process::exit(1);
    }
}
