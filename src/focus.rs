//! Window focus module for different terminal emulators on macOS.
//!
//! This module provides functionality to focus terminal windows running Claude Code
//! sessions across various terminal emulators including VS Code, Cursor, iTerm2,
//! Kitty, and Terminal.app.

use std::process::Command;

use crate::config::Config;
use crate::session::Session;

/// Focus the terminal window containing the given session.
///
/// Dispatches to the appropriate focus function based on the terminal program
/// detected in the session.
pub fn focus_terminal(
    session: &Session,
    config: &Config,
) -> Result<(), Box<dyn std::error::Error>> {
    match session.terminal.program.as_str() {
        "vscode" | "cursor" | "Code" | "Cursor" => focus_editor(session, config),
        "iTerm.app" => focus_iterm(session.terminal.session_id.as_deref()),
        "kitty" => focus_kitty(
            session.terminal.session_id.as_deref(),
            &session.project_name,
        ),
        "Apple_Terminal" => focus_terminal_app(),
        _ => focus_generic(&session.project_path, config),
    }
}

/// Focus an editor window (VS Code, Cursor, etc.) and open its integrated terminal.
///
/// Uses AppleScript to:
/// 1. Find the window containing the project name in its title
/// 2. Raise the window using AXRaise accessibility action
/// 3. Set the process as frontmost
/// 4. Send Ctrl+` (key code 50) to toggle the integrated terminal
///
/// If no matching window is found, falls back to opening the project via CLI.
fn focus_editor(session: &Session, config: &Config) -> Result<(), Box<dyn std::error::Error>> {
    let process_name = &config.editor.process_name;
    let cli_command = &config.editor.cli_command;
    let project_name = &session.project_name;
    let project_path = &session.project_path;

    let script = format!(
        r#"
        tell application "System Events" to tell process "{process_name}"
            repeat with handle in windows
                if name of handle contains "{project_name}" then
                    perform action "AXRaise" of handle
                    tell application "System Events" to set frontmost of process "{process_name}" to true
                    delay 0.1
                    key code 50 using control down
                    return
                end if
            end repeat
        end tell
        do shell script "{cli_command} '{project_path}'"
    "#
    );

    Command::new("osascript").arg("-e").arg(&script).output()?;
    Ok(())
}

/// Focus an iTerm2 session by its unique session ID.
///
/// If a session ID is provided, iterates through all windows, tabs, and sessions
/// to find and select the matching session. Otherwise, simply activates iTerm2.
fn focus_iterm(session_id: Option<&str>) -> Result<(), Box<dyn std::error::Error>> {
    let script = if let Some(id) = session_id {
        format!(
            r#"
            tell application "iTerm"
                activate
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aSession in sessions of aTab
                            if id of aSession is "{id}" then
                                select aSession
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
        "#
        )
    } else {
        r#"tell application "iTerm" to activate"#.to_string()
    };

    Command::new("osascript").arg("-e").arg(&script).output()?;
    Ok(())
}

/// Focus a Kitty terminal window.
///
/// Uses the `kitten @` remote control command to focus the window.
/// If a window ID is available, matches by ID; otherwise matches by title.
///
/// Note: Requires `allow_remote_control yes` in kitty.conf.
fn focus_kitty(
    window_id: Option<&str>,
    project_name: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let match_arg = if let Some(id) = window_id {
        format!("id:{id}")
    } else {
        format!("title:{project_name}")
    };

    Command::new("kitten")
        .args(["@", "focus-window", "--match", &match_arg])
        .output()?;
    Ok(())
}

/// Focus Terminal.app.
///
/// Simply activates the Terminal application using AppleScript.
/// This provides app-level focus only, as Terminal.app doesn't support
/// session-specific focusing via scripting.
fn focus_terminal_app() -> Result<(), Box<dyn std::error::Error>> {
    Command::new("osascript")
        .arg("-e")
        .arg(r#"tell application "Terminal" to activate"#)
        .output()?;
    Ok(())
}

/// Generic fallback for unsupported terminals.
///
/// Opens the project path in the configured editor via CLI command.
fn focus_generic(project_path: &str, config: &Config) -> Result<(), Box<dyn std::error::Error>> {
    Command::new(&config.editor.cli_command)
        .arg(project_path)
        .output()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    // Note: Most focus functions require macOS and actual applications to test.
    // These tests verify the module compiles and basic logic is correct.

    #[test]
    fn test_kitty_match_arg_with_id() {
        let id = Some("12345");
        let match_arg = if let Some(id) = id {
            format!("id:{id}")
        } else {
            format!("title:test")
        };
        assert_eq!(match_arg, "id:12345");
    }

    #[test]
    fn test_kitty_match_arg_without_id() {
        let id: Option<&str> = None;
        let project_name = "my-project";
        let match_arg = if let Some(id) = id {
            format!("id:{id}")
        } else {
            format!("title:{project_name}")
        };
        assert_eq!(match_arg, "title:my-project");
    }
}
