import AppKit

// MARK: - Strategy (testable, pure logic)

/// Describes how to focus a terminal session. Resolved by pure logic, executed by AppKit.
enum FocusStrategy: Equatable {
    /// Open a file/folder with a specific app via its bundle ID.
    case openWithApp(bundleID: String, target: String)
    /// Focus an iTerm2 session by its unique GUID, with a bundle ID fallback.
    case iTerm2(guid: String)
    /// Focus a Kitty window via remote control socket, with bundle ID fallback.
    case kitty(socket: String, windowId: String, binaryPath: String)
    /// Focus a Ghostty terminal by matching its working directory, with a bundle ID fallback.
    case ghostty(workingDirectory: String)
    /// Focus an Apple Terminal tab by its tty (e.g. /dev/ttys003), with a bundle ID fallback.
    case appleTerminal(tty: String)
    /// Activate a running app by its localized name.
    case activateByName(String)
    /// Activate a running app by its bundle identifier.
    case activateByBundleID(String)
    /// Open an app-specific deep link URL (e.g. claude://resume?session=...).
    case openURL(URL)
    /// Open a path in Finder.
    case openInFinder(String)
}

/// Resolve which strategy to use for jumping to a session.
/// Pure function — no AppKit side effects, fully testable.
func resolveFocusStrategy(session: Session) -> FocusStrategy {
    guard let terminal = session.terminal else {
        return .openInFinder(session.projectPath)
    }

    // Prefer bundle_id (from __CFBundleIdentifier) over program name — it
    // unambiguously identifies VS Code forks that all set TERM_PROGRAM=vscode.
    let hostApp = HostApp.from(bundleIdentifier: terminal.bundleId)
        ?? HostApp.from(editorName: terminal.program)
    let target = session.workspaceFile ?? session.projectPath

    // Falls through to bundle-ID activation below if the session ID isn't a
    // valid UUID, so the user still gets the app focused.
    if let url = hostApp.sessionDeepLink(sessionId: session.sessionId) {
        return .openURL(url)
    }

    // Editors with a known bundle ID → open the project with that app.
    // Uses NSWorkspace instead of CLI (e.g., `code <path>`) to avoid PATH issues
    // when the app is relaunched by Sparkle (minimal PATH, CLI not found).
    // Tradeoff: NSWorkspace goes through LaunchServices rather than the editor's IPC,
    // so users with `window.openFoldersInNewWindow: "on"` may get a new window
    // instead of focusing the existing one. The default ("default") reuses existing windows.
    if hostApp.cliCommand != nil, let bundleID = hostApp.bundleID {
        return .openWithApp(bundleID: bundleID, target: target)
    }

    // iTerm2 → AppleScript to focus the specific session
    if hostApp == .iterm2,
       let guid = extractITermGUID(from: terminal.sessionId),
       guid.range(of: #"^[0-9a-fA-F-]+$"#, options: .regularExpression) != nil {
        return .iTerm2(guid: guid)
    }

    // Kitty → remote control to focus the specific window (pane in Kitty's terms)
    if hostApp == .kitty,
       let socket = terminal.socket,
       let windowId = terminal.sessionId,
       let binaryPath = terminal.binaryPaths?["kitty"] {
        return .kitty(socket: socket, windowId: windowId, binaryPath: binaryPath)
    }

    if hostApp == .ghostty {
        return .ghostty(workingDirectory: session.projectPath)
    }

    // Apple Terminal → AppleScript to focus the specific tab by tty.
    // NSRunningApplication.activate() can't target a single tab, and on macOS
    // Sonoma+ cooperative activation often fails to even raise the app.
    if hostApp == .terminal,
       let tty = terminal.tty,
       tty.range(of: #"^/dev/ttys\d+$"#, options: .regularExpression) != nil {
        return .appleTerminal(tty: tty)
    }

    // Try activation by name, then bundle ID, then Finder
    if let name = hostApp.activationName {
        return .activateByName(name)
    }
    if let bundleID = hostApp.bundleID {
        return .activateByBundleID(bundleID)
    }
    return .openInFinder(session.projectPath)
}

// MARK: - Multiplexer focus (independent of emulator focus)

/// Describes how to focus a specific pane inside a terminal multiplexer.
enum MultiplexerFocusStrategy: Equatable {
    /// zellij --session $sessionName action focus-pane-id $paneId
    case zellij(sessionName: String, paneId: String, binaryPath: String)
    /// tmux -S $socket select-window -t $paneId && tmux -S $socket select-pane -t $paneId
    case tmux(socket: String, paneId: String, binaryPath: String)
}

/// Resolve multiplexer focus from session info. Returns nil when no multiplexer is present.
/// Pure function — no side effects, fully testable.
func resolveMultiplexerFocus(session: Session) -> MultiplexerFocusStrategy? {
    guard let mux = session.terminal?.multiplexer else { return nil }
    switch mux {
    case .zellij(let sessionName, let paneId, let binaryPath):
        guard let binaryPath else { return nil }
        return .zellij(sessionName: sessionName, paneId: paneId, binaryPath: binaryPath)
    case .tmux(let socket, let paneId, let binaryPath):
        guard let binaryPath else { return nil }
        return .tmux(socket: socket, paneId: paneId, binaryPath: binaryPath)
    }
}

// MARK: - Execution (AppKit side effects)

func focusTerminal(session: Session) {
    let strategy = resolveFocusStrategy(session: session)
    let muxStrategy = resolveMultiplexerFocus(session: session)
    if case .ghostty(let cwd) = strategy, let tty = session.terminal?.tty {
        primeGhosttyCWD(tty: tty, workingDirectory: cwd)
    }
    executeFocusStrategy(strategy)
    if let mux = muxStrategy {
        DispatchQueue.global(qos: .userInitiated).async {
            executeMultiplexerFocus(mux)
        }
    }
    NSApp.deactivate()
}

private func executeFocusStrategy(_ strategy: FocusStrategy) {
    switch strategy {
    case .openWithApp(let bundleID, let target):
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open(
                [URL(fileURLWithPath: target)],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            // App not installed — open in Finder
            NSWorkspace.shared.open(URL(fileURLWithPath: target))
        }

    case .iTerm2(let guid):
        runScriptOrActivate(.iterm2) { executeITerm2Script(guid: guid) }

    case .kitty(let socket, let windowId, let binaryPath):
        runScriptOrActivate(.kitty) {
            executeKittyFocusWindow(binaryPath: binaryPath, socket: socket, windowId: windowId)
        }

    case .ghostty(let workingDirectory):
        runScriptOrActivate(.ghostty) { executeGhosttyFocusScript(workingDirectory: workingDirectory) }

    case .appleTerminal(let tty):
        runScriptOrActivate(.terminal) { executeAppleTerminalScript(tty: tty) }

    case .activateByName(let name):
        activateAppByName(name)

    case .activateByBundleID(let bundleID):
        activateAppByBundleID(bundleID)

    case .openURL(let url):
        NSWorkspace.shared.open(url)

    case .openInFinder(let path):
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

/// Run a focus script for `host`; if it fails, fall back to activating the host by bundle ID.
private func runScriptOrActivate(_ host: HostApp, script: () -> Bool) {
    if !script(), let bundleID = host.bundleID {
        activateAppByBundleID(bundleID)
    }
}

// MARK: - iTerm2 AppleScript

func extractITermGUID(from sessionId: String?) -> String? {
    guard let id = sessionId, !id.isEmpty else { return nil }
    guard let colonIndex = id.lastIndex(of: ":") else { return id }
    return String(id[id.index(after: colonIndex)...])
}

private func runAppleScript(_ source: String) -> Bool {
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
    return error == nil
}

private func executeITerm2Script(guid: String) -> Bool {
    runAppleScript("""
    tell application "iTerm2"
        activate
        repeat with w in windows
            tell w
                repeat with t in tabs
                    tell t
                        repeat with s in sessions
                            if (unique id of s) is equal to "\(guid)" then
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
    """)
}

// MARK: - Apple Terminal AppleScript
// Each Terminal tab exposes its `tty` (e.g. /dev/ttys003) over AppleScript. For
// a shell running directly in a tab the match is unambiguous. Under a multiplexer
// (tmux, screen) the captured tty is the multiplexer pane's pty and won't appear
// in Terminal's tab list — the loop no-ops, but the leading `activate` still
// raises the app (the previous .activateByName behavior, more reliable on Sonoma+).

private func executeAppleTerminalScript(tty: String) -> Bool {
    runAppleScript("""
    tell application "Terminal"
        activate
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is "\(tty)" then
                    set miniaturized of w to false
                    set selected of t to true
                    set frontmost of w to true
                    return
                end if
            end repeat
        end repeat
    end tell
    """)
}

// MARK: - Ghostty AppleScript
// Ghostty 1.3.0+ exposes an AppleScript API (windows → tabs → terminals).
// Each `terminal` (= one split/pane) has `id`, `name`, `working directory`.
// No env var carries the terminal id into the shell yet, so we match on cwd —
// best-effort: ambiguous when multiple Ghostty splits share the same cwd
// (picks first), and breaks if the user `cd`s elsewhere after session start.
//
// Before running the AppleScript we write an OSC 7 cwd report directly to the
// session's TTY (captured at hook time, e.g. /dev/ttys011). Ghostty parses OSC 7
// off the PTY master and updates `working directory of term`. This makes the
// match deterministic even when the shell never emits OSC 7 itself (e.g. when
// Ghostty's shell integration isn't loaded by a wrapper-launched shell).
//
// We walk windows → tabs → terminals (instead of `every terminal whose …`) so
// we keep a reference to the parent window, then call `activate window` on it
// before focusing the surface. The leading `activate` only raises whichever
// Ghostty window was most recently active, so without the explicit
// `activate window w` the wrong window can stay on top when the user clicks
// a session whose window is sitting behind another Ghostty window.
//
// Tracked upstream:
//   - ghostty-org/ghostty#9084  (TERM_SESSION_ID request)
//   - ghostty-org/ghostty#10603 (GHOSTTY_SURFACE_ID env var + URL scheme)
// FUTURE: when GHOSTTY_SURFACE_ID ships, capture it in
// HookHandler.captureTerminalInfo() and switch this script to `whose id is …`
// for an exact, unambiguous match (analogous to iTerm2's GUID strategy).

/// Escape a string for safe interpolation inside an AppleScript double-quoted literal.
func escapeAppleScriptString(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

/// Build the OSC 7 byte sequence (`ESC ] 7 ; file://HOST/PATH BEL`).
/// Path is URL-encoded so spaces / non-ASCII don't break the URI form.
func buildOSC7CWD(host: String, workingDirectory: String) -> String {
    let encoded = workingDirectory
        .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workingDirectory
    return "\u{1B}]7;file://\(host)\(encoded)\u{07}"
}

private func executeGhosttyFocusScript(workingDirectory: String) -> Bool {
    let escaped = escapeAppleScriptString(workingDirectory)
    return runAppleScript("""
    tell application "Ghostty"
        activate
        repeat with w in windows
            repeat with t in tabs of w
                repeat with term in terminals of t
                    if working directory of term is "\(escaped)" then
                        activate window w
                        select tab t
                        focus term
                        return
                    end if
                end repeat
            end repeat
        end repeat
    end tell
    """)
}

/// Bytes written to the slave (`/dev/ttysNNN`) appear on the PTY master where Ghostty
/// parses them; the shell does not see them. Best-effort — silently no-ops if the TTY
/// has closed (session just ended).
private func primeGhosttyCWD(tty: String, workingDirectory: String) {
    // Allow only PTY slaves (`/dev/ttys<digits>`) — that's the only shape
    // cctop-hook captures from `ps -o tty=`. This rejects /dev/cu.*, /dev/console,
    // and arbitrary file paths a tampered session JSON might supply.
    guard tty.range(of: #"^/dev/ttys\d+$"#, options: .regularExpression) != nil else { return }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: tty),
          (attrs[.type] as? FileAttributeType) == .typeCharacterSpecial else { return }
    let host = ProcessInfo.processInfo.hostName
    let osc = buildOSC7CWD(host: host, workingDirectory: workingDirectory)
    guard let data = osc.data(using: .utf8) else { return }
    guard let handle = FileHandle(forWritingAtPath: tty) else { return }
    defer { try? handle.close() }
    try? handle.write(contentsOf: data)
}

// MARK: - Kitty Remote Control
// https://sw.kovidgoyal.net/kitty/remote-control/

private func executeKittyFocusWindow(binaryPath: String, socket: String, windowId: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)
    process.arguments = ["@", "--to", socket, "focus-window", "--match", "id:\(windowId)"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

// MARK: - Open recent project in editor

func openInEditor(project: RecentProject) {
    guard let editor = project.lastEditor, !editor.isEmpty else {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.projectPath)
        return
    }

    let hostApp = HostApp.from(editorName: editor)

    // For code editors, prefer stored workspace file, fallback to dynamic lookup
    let target: String
    if hostApp.usesWorkspaceFile {
        target = project.workspaceFile
            ?? Session.findWorkspaceFile(in: project.projectPath)
            ?? project.projectPath
    } else {
        target = project.projectPath
    }

    // Try bundle ID launch first
    if let bundleID = hostApp.bundleID,
       let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: target)],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
        return
    }

    // Fallback: try `open -a <editor> <path>`
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", editor, target]
    if (try? process.run()) != nil { return }

    // Final fallback: open in Finder
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.projectPath)
}

// MARK: - App activation helpers

@discardableResult
private func activateAppByBundleID(_ bundleID: String) -> Bool {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == bundleID
    }) else {
        return false
    }
    app.activate()
    return true
}

@discardableResult
private func activateAppByName(_ program: String) -> Bool {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName?.lowercased().contains(program) == true
    }) else {
        return false
    }
    app.activate()
    return true
}

// MARK: - Multiplexer focus execution
// Failures are silently ignored — the emulator was already focused,
// which is better than nothing.

private func executeMultiplexerFocus(_ strategy: MultiplexerFocusStrategy) {
    switch strategy {
    case .zellij(let sessionName, let paneId, let binaryPath):
        executeZellijFocus(binaryPath: binaryPath, sessionName: sessionName, paneId: paneId)
    case .tmux(let socket, let paneId, let binaryPath):
        executeTmuxFocus(binaryPath: binaryPath, socket: socket, paneId: paneId)
    }
}

// https://zellij.dev/documentation/controlling-zellij-through-cli
private func executeZellijFocus(binaryPath: String, sessionName: String, paneId: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)
    process.arguments = ["--session", sessionName, "action", "focus-pane-id", paneId]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {}
}

// https://man.openbsd.org/tmux.1
// select-window switches to the window containing the pane;
// select-pane then activates the specific pane within that window.
private func executeTmuxFocus(binaryPath: String, socket: String, paneId: String) {
    for cmd in [["select-window", "-t", paneId], ["select-pane", "-t", paneId]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["-S", socket] + cmd
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}
    }
}
