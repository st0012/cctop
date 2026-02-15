// Jump-to-session action logic, replicating FocusTerminal.swift behavior
import { execFileSync } from "child_process";
import { closeMainWindow, popToRoot, showToast, Toast } from "@raycast/api";
import { CctopSession } from "./types";

/**
 * Extract the iTerm2 GUID from a terminal session ID string.
 * iTerm2 format: "w0t0p0:GUID" — we want the part after the last colon.
 * Matches extractITermGUID() in FocusTerminal.swift.
 */
function extractITermGUID(sessionId: string | null | undefined): string | null {
  if (!sessionId) return null;
  const colonIndex = sessionId.lastIndexOf(":");
  if (colonIndex === -1) return sessionId;
  return sessionId.substring(colonIndex + 1);
}

/**
 * Build the AppleScript to focus a specific iTerm2 session by GUID.
 * Matches the AppleScript in FocusTerminal.swift:focusITerm2Session().
 */
function buildITermScript(guid: string): string {
  // Escape double quotes in the GUID (shouldn't normally contain them, but be safe)
  const escaped = guid.replace(/"/g, '\\"');
  return `
    tell application "iTerm2"
      activate
      repeat with w in windows
        tell w
          repeat with t in tabs
            tell t
              repeat with s in sessions
                if (unique id of s) is equal to "${escaped}" then
                  set index of w to 1
                  select t
                  tell s to select
                  return
                end if
              end repeat
            end tell
          end repeat
        end tell
      end repeat
    end tell
  `;
}

/**
 * Return a human-readable label for the terminal program.
 * Used for contextual action labels like "Open in VS Code".
 */
export function getTerminalLabel(session: CctopSession): string {
  const program = session.terminal?.program?.toLowerCase() ?? "";
  if (program.includes("cursor")) return "Cursor";
  if (program.includes("windsurf")) return "Windsurf";
  if (program.includes("code")) return "VS Code";
  if (program.includes("iterm")) return "iTerm2";
  if (program.includes("warp")) return "Warp";
  if (program.includes("terminal")) return "Terminal";
  if (session.terminal?.program) return session.terminal.program;
  return "Finder";
}

/**
 * Focus the terminal/editor for a session, then dismiss Raycast.
 * Replicates the logic in FocusTerminal.swift:focusTerminal().
 */
export async function jumpToSession(session: CctopSession): Promise<void> {
  try {
    const program = session.terminal?.program?.toLowerCase() ?? "";
    const target = session.workspace_file ?? session.project_path;

    if (
      program.includes("code") ||
      program.includes("cursor") ||
      program.includes("windsurf")
    ) {
      // Use macOS `open -a` to focus the editor window.
      // Raycast's sandbox doesn't have /usr/local/bin in PATH so CLI tools
      // like `code` can't be found, but `open` is in /usr/bin/ and uses
      // Launch Services to resolve the app.
      const appName = program.includes("cursor")
        ? "Cursor"
        : program.includes("windsurf")
          ? "Windsurf"
          : "Visual Studio Code";
      execFileSync("open", ["-a", appName, target]);
    } else if (program.includes("iterm")) {
      // iTerm2: use AppleScript to find and focus the specific session
      const guid = extractITermGUID(session.terminal?.session_id);
      if (guid) {
        execFileSync("osascript", ["-e", buildITermScript(guid)]);
      } else {
        execFileSync("open", ["-a", "iTerm"]);
      }
    } else if (program.includes("warp")) {
      execFileSync("open", ["-a", "Warp"]);
    } else if (session.terminal?.program) {
      // Generic terminal: try activating the app by name first (matches Swift's activateAppByName)
      try {
        execFileSync("open", ["-a", session.terminal.program]);
      } catch {
        execFileSync("open", [session.project_path]);
      }
    } else {
      // No terminal info: open project path in Finder
      execFileSync("open", [session.project_path]);
    }

    await closeMainWindow();
    await popToRoot();
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await showToast({
      style: Toast.Style.Failure,
      title: "Failed to focus session",
      message: msg,
    });
  }
}
