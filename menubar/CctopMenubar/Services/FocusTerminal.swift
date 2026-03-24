import AppKit

// MARK: - Strategy (testable, pure logic)

/// Describes how to focus a terminal session. Resolved by pure logic, executed by AppKit.
enum FocusStrategy: Equatable {
    /// Open a file/folder with a specific app via its bundle ID.
    case openWithApp(bundleID: String, target: String)
    /// Focus an iTerm2 session by its unique GUID, with a bundle ID fallback.
    case iTerm2(guid: String)
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

    // Try activation by name, then bundle ID, then Finder
    if let name = hostApp.activationName {
        return .activateByName(name)
    }
    if let bundleID = hostApp.bundleID {
        return .activateByBundleID(bundleID)
    }
    return .openInFinder(session.projectPath)
}

// MARK: - Execution (AppKit side effects)

func focusTerminal(session: Session) {
    let strategy = resolveFocusStrategy(session: session)
    executeFocusStrategy(strategy)
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

private func executeITerm2Script(guid: String) -> Bool {
    let script = """
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
    """
    var error: NSDictionary?
    NSAppleScript(source: script)?.executeAndReturnError(&error)
    return error == nil
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
