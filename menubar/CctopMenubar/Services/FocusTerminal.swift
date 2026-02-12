import AppKit

func focusTerminal(session: Session) {
    guard let terminal = session.terminal else {
        NSWorkspace.shared.open(URL(fileURLWithPath: session.projectPath))
        return
    }
    let program = terminal.program.lowercased()

    if program.contains("code") || program.contains("cursor") {
        focusEditor(session: session, isCursor: program.contains("cursor"))
    } else if let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName?.lowercased().contains(program) == true
    }) {
        app.activate()
    } else {
        NSWorkspace.shared.open(URL(fileURLWithPath: session.projectPath))
    }
}

// MARK: - VS Code / Cursor

private func focusEditor(session: Session, isCursor: Bool) {
    let bundleId = isCursor ? "com.todesktop.230313mzl4w4u92" : "com.microsoft.VSCode"
    let cliSubpath = isCursor ? "cursor" : "code"

    // Use the CLI binary inside the app bundle — handles window reuse correctly
    // and doesn't depend on shell PATH (which GUI apps don't have).
    if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
        let cli = appUrl.appendingPathComponent("Contents/Resources/app/bin/\(cliSubpath)")
        if FileManager.default.isExecutableFile(atPath: cli.path) {
            let process = Process()
            process.executableURL = cli
            process.arguments = [session.projectPath]
            try? process.run()
            return
        }
    }

    // Fallback: open -a (always available, no PATH dependency)
    let appName = isCursor ? "Cursor" : "Visual Studio Code"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", appName, session.projectPath]
    try? process.run()
}
