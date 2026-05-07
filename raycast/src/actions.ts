// Jump-to-session action logic, replicating FocusTerminal.swift behavior
import { execFileSync } from "child_process";
import { statSync, writeFileSync } from "node:fs";
import { hostname } from "node:os";
import { closeMainWindow, popToRoot } from "@raycast/api";
import { showFailureToast } from "@raycast/utils";
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

/** iTerm2 GUIDs are hex strings with hyphens (e.g. "w0t0p0:XXXXXXXX-..."). */
function isValidGUID(s: string): boolean {
  return /^[0-9a-fA-F-]+$/.test(s);
}

/** Escape a string for safe interpolation inside an AppleScript double-quoted literal. */
function escapeAppleScriptString(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

/**
 * Bytes written to the slave (`/dev/ttysNNN`) appear on the PTY master where Ghostty
 * parses them; the shell does not see them. Best-effort — silently no-ops if the TTY
 * has closed. Mirrors `primeGhosttyCWD` in FocusTerminal.swift.
 */
function primeGhosttyCWD(tty: string, workingDirectory: string): void {
  try {
    // Allow only PTY slaves (`/dev/ttys<digits>`) — that's the only shape
    // cctop-hook captures from `ps -o tty=`. This rejects /dev/cu.*, /dev/console,
    // and arbitrary file paths a tampered session JSON might supply.
    if (!/^\/dev\/ttys\d+$/.test(tty)) return;
    if (!statSync(tty).isCharacterDevice()) return;
    // encodeURI leaves '#' and '?' unencoded; post-encode to match Swift's `.urlPathAllowed`.
    const encoded = encodeURI(workingDirectory)
      .replace(/#/g, "%23")
      .replace(/\?/g, "%3F");
    const osc = `\x1b]7;file://${hostname()}${encoded}\x07`;
    writeFileSync(tty, osc);
  } catch {
    // best-effort
  }
}

/**
 * Build the AppleScript to focus a Ghostty terminal whose working directory matches.
 * Mirrors executeGhosttyFocusScript() in FocusTerminal.swift.
 *
 * We walk windows → tabs → terminals so we keep a reference to the parent window
 * and call `activate window w` on it before focusing the surface. Without the
 * explicit window activation, the leading `activate` only raises whichever
 * Ghostty window was most recently active — so a click on a session whose
 * window is behind another Ghostty window leaves the wrong window on top.
 *
 * Best-effort: Ghostty does not yet expose a per-surface env var inside the shell
 * (see ghostty-org/ghostty#9084, #10603), so we cannot do an exact-id match like
 * iTerm2/Kitty. When GHOSTTY_SURFACE_ID ships, switch to id-based matching.
 */
function buildGhosttyScript(workingDirectory: string): string {
  const escaped = escapeAppleScriptString(workingDirectory);
  return `
    tell application "Ghostty"
      activate
      repeat with w in windows
        repeat with t in tabs of w
          repeat with term in terminals of t
            if working directory of term is "${escaped}" then
              activate window w
              select tab t
              focus term
              return
            end if
          end repeat
        end repeat
      end repeat
    end tell
  `;
}

/**
 * Build the AppleScript to focus a specific iTerm2 session by GUID.
 * Matches the AppleScript in FocusTerminal.swift:focusITerm2Session().
 * Caller must validate the GUID with isValidGUID() before calling this.
 */
function buildITermScript(guid: string): string {
  return `
    tell application "iTerm2"
      activate
      repeat with w in windows
        tell w
          repeat with t in tabs
            tell t
              repeat with s in sessions
                if (unique id of s) is equal to "${guid}" then
                  set miniaturized of w to false
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
  if (program.includes("ghostty")) return "Ghostty";
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
    const bundleId = session.terminal?.bundle_id ?? "";
    const target = session.workspace_file ?? session.project_path;

    // Bundle ID is more reliable than TERM_PROGRAM: when a multiplexer (tmux,
    // zellij) runs inside Ghostty, TERM_PROGRAM becomes the multiplexer name
    // while __CFBundleIdentifier still identifies the host emulator. Mirrors
    // HostApp.from(bundleIdentifier:) in the Swift menubar app.
    const isGhostty =
      program.includes("ghostty") || bundleId === "com.mitchellh.ghostty";

    if (
      program.includes("code") ||
      program.includes("cursor") ||
      program.includes("windsurf")
    ) {
      let appName = "Visual Studio Code";
      if (program.includes("cursor")) appName = "Cursor";
      else if (program.includes("windsurf")) appName = "Windsurf";
      execFileSync("open", ["-a", appName, target]);
    } else if (program.includes("iterm")) {
      // iTerm2: use AppleScript to find and focus the specific session
      const guid = extractITermGUID(session.terminal?.session_id);
      if (guid && isValidGUID(guid)) {
        execFileSync("osascript", ["-e", buildITermScript(guid)]);
      } else {
        execFileSync("open", ["-a", "iTerm"]);
      }
    } else if (program.includes("warp")) {
      execFileSync("open", ["-a", "Warp"]);
    } else if (isGhostty) {
      // Ghostty 1.3.0+ exposes AppleScript; match the terminal by working directory.
      if (session.terminal?.tty) {
        primeGhosttyCWD(session.terminal.tty, session.project_path);
      }
      try {
        execFileSync("osascript", [
          "-e",
          buildGhosttyScript(session.project_path),
        ]);
      } catch {
        execFileSync("open", ["-a", "Ghostty"]);
      }
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
    await showFailureToast(e, { title: "Failed to focus session" });
  }
}
