import Foundation

/// Exact pane/tab targeting for terminals that support it. Returns nil when the
/// host has no pane-targeting support or the required metadata is missing, so
/// the caller falls through to plain app activation.
func resolveTerminalPaneFocus(hostApp: HostApp, session: SessionData) -> FocusStrategy? {
    let terminal = session.terminal

    // Warp → session deep link; Launch Services opens it with the channel app
    // and activates it. See WarpFocusLink.
    if hostApp == .warp, let url = WarpFocusLink.validatedURL(terminal?.focusUrl) {
        return .openURL(url)
    }

    // iTerm2 → AppleScript to focus the specific session
    if hostApp == .iterm2,
       let guid = extractITermGUID(from: terminal?.sessionId),
       guid.range(of: #"^[0-9a-fA-F-]+$"#, options: .regularExpression) != nil {
        return .iTerm2(guid: guid)
    }

    // Kitty → remote control to focus the specific window (pane in Kitty's terms)
    if hostApp == .kitty,
       let socket = terminal?.socket,
       let windowId = terminal?.sessionId,
       let binaryPath = terminal?.binaryPaths?["kitty"] {
        return .kitty(socket: socket, windowId: windowId, binaryPath: binaryPath)
    }

    if hostApp == .ghostty {
        return .ghostty(ghosttyFocusTarget(for: session))
    }

    // Apple Terminal → AppleScript to focus the specific tab by tty.
    // NSRunningApplication.activate() can't target a single tab, and on macOS
    // Sonoma+ cooperative activation often fails to even raise the app.
    if hostApp == .terminal,
       let tty = terminal?.tty,
       tty.range(of: #"^/dev/ttys\d+$"#, options: .regularExpression) != nil {
        return .appleTerminal(tty: tty)
    }

    return nil
}
