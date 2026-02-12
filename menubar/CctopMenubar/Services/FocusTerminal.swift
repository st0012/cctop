import AppKit

func focusTerminal(session: Session) {
    guard let terminal = session.terminal else {
        NSWorkspace.shared.open(URL(fileURLWithPath: session.projectPath))
        return
    }
    let program = terminal.program.lowercased()

    if program.contains("code") || program.contains("cursor") {
        let cli = program.contains("cursor") ? "cursor" : "code"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [cli, "--goto", session.projectPath]
        try? process.run()
    } else if let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName?.lowercased().contains(program) == true
    }) {
        app.activate()
    } else {
        NSWorkspace.shared.open(URL(fileURLWithPath: session.projectPath))
    }
}
