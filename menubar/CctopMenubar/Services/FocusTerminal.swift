import AppKit

func focusTerminal(session: Session) {
    guard let terminal = session.terminal else {
        NSWorkspace.shared.open(URL(fileURLWithPath: session.projectPath))
        return
    }
    let program = terminal.program.lowercased()

    if program.contains("code") || program.contains("cursor") {
        let cli = program.contains("cursor") ? "cursor" : "code"
        let target = session.workspaceFile ?? session.projectPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [cli, target]
        try? process.run()
    } else if program.contains("iterm") {
        if !focusITerm2Session(sessionId: terminal.sessionId) {
            activateAppByName(program)
        }
    } else if !activateAppByName(program) {
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
