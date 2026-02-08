import AppKit

func focusTerminal(session: Session) {
    let program = session.terminal.program.lowercased()

    if program.contains("code") || program.contains("cursor") {
        // VS Code / Cursor: use CLI --goto
        let cli = program.contains("cursor") ? "cursor" : "code"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [cli, "--goto", session.projectPath]
        try? process.run()
    } else if program.contains("iterm") {
        // iTerm2: AppleScript
        let script = """
        tell application "iTerm"
            activate
            tell current window
                select
            end tell
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    } else {
        // Generic: try to activate by name
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased().contains(program) == true
        }) {
            app.activate()
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: session.projectPath))
        }
    }
}
