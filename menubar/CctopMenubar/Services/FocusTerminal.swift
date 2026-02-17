import AppKit

func focusTerminal(session: Session) {
    guard let terminal = session.terminal else {
        NSWorkspace.shared.open(URL(fileURLWithPath: session.projectPath))
        return
    }

    let hostApp = HostApp.from(editorName: terminal.program)

    if let cli = hostApp.cliCommand {
        let target = session.workspaceFile ?? session.projectPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [cli, target]
        try? process.run()
    } else if hostApp == .iterm2 {
        if !focusITerm2Session(sessionId: terminal.sessionId) {
            if let name = hostApp.activationName { activateAppByName(name) }
        }
    } else if let name = hostApp.activationName, activateAppByName(name) {
        // activated successfully
    } else {
        NSWorkspace.shared.open(URL(fileURLWithPath: session.projectPath))
    }
}

func extractITermGUID(from sessionId: String?) -> String? {
    guard let id = sessionId, !id.isEmpty else { return nil }
    guard let colonIndex = id.lastIndex(of: ":") else { return id }
    return String(id[id.index(after: colonIndex)...])
}

private func focusITerm2Session(sessionId: String?) -> Bool {
    guard let guid = extractITermGUID(from: sessionId),
          guid.range(of: #"^[0-9a-fA-F-]+$"#, options: .regularExpression) != nil
    else { return false }

    let script = """
    tell application "iTerm2"
        activate
        repeat with w in windows
            tell w
                repeat with t in tabs
                    tell t
                        repeat with s in sessions
                            if (unique id of s) is equal to "\(guid)" then
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
