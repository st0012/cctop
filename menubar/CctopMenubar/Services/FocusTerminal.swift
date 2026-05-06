import AppKit

// MARK: - Strategy (testable, pure logic)

/// Describes how to focus a terminal session. Resolved by pure logic, executed by AppKit.
enum FocusStrategy: Equatable {
    /// Open a file/folder with a specific app via its bundle ID.
    case openWithApp(bundleID: String, target: String)
    /// Focus an iTerm2 session by its unique GUID, with a bundle ID fallback.
    case iTerm2(guid: String)
    /// Focus a Kitty window via remote control socket, with bundle ID fallback.
    case kitty(socket: String, windowId: String)
    /// Focus a Ghostty terminal by matching its working directory, with a bundle ID fallback.
    case ghostty(workingDirectory: String)
    /// Activate a running app by its localized name.
    case activateByName(String)
    /// Activate a running app by its bundle identifier.
    case activateByBundleID(String)
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
       let windowId = terminal.sessionId {
        return .kitty(socket: socket, windowId: windowId)
    }

    if hostApp == .ghostty {
        return .ghostty(workingDirectory: session.projectPath)
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
        if !executeITerm2Script(guid: guid) {
            if let bundleID = HostApp.iterm2.bundleID {
                activateAppByBundleID(bundleID)
            }
        }

    case .kitty(let socket, let windowId):
        if !executeKittyFocusWindow(socket: socket, windowId: windowId) {
            if let bundleID = HostApp.kitty.bundleID {
                activateAppByBundleID(bundleID)
            }
        }

    case .ghostty(let workingDirectory):
        if !executeGhosttyFocusScript(workingDirectory: workingDirectory) {
            if let bundleID = HostApp.ghostty.bundleID {
                activateAppByBundleID(bundleID)
            }
        }

    case .activateByName(let name):
        activateAppByName(name)

    case .activateByBundleID(let bundleID):
        activateAppByBundleID(bundleID)

    case .openInFinder(let path):
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
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

// MARK: - Ghostty AppleScript
// Ghostty 1.3.0+ exposes an AppleScript API (windows → tabs → terminals).
// Each `terminal` (= one split/pane) has `id`, `name`, `working directory`.
// No env var carries the terminal id into the shell yet, so we match on cwd —
// best-effort: ambiguous when multiple Ghostty splits share the same cwd
// (picks first), and breaks if the user `cd`s elsewhere after session start.
// The script's leading `activate` covers the no-match case (plain app focus),
// so a separate fallback isn't needed unless the script itself errors.
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

private func executeGhosttyFocusScript(workingDirectory: String) -> Bool {
    let escaped = escapeAppleScriptString(workingDirectory)
    return runAppleScript("""
    tell application "Ghostty"
        activate
        set matches to (every terminal whose working directory is "\(escaped)")
        if (count of matches) > 0 then
            focus (item 1 of matches)
            return
        end if
    end tell
    """)
}

// MARK: - Kitty Remote Control
// https://sw.kovidgoyal.net/kitty/remote-control/

private func executeKittyFocusWindow(socket: String, windowId: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["kitty", "@", "--to", socket, "focus-window", "--match", "id:\(windowId)"]
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
