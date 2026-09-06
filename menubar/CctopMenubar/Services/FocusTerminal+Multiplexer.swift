import Foundation

/// Describes how to focus a specific pane inside a terminal multiplexer.
enum MultiplexerFocusStrategy: Equatable {
    /// cmux --socket $socket focus-surface --workspace $workspaceId --surface $surfaceId
    case cmux(socket: String, workspaceId: String, surfaceId: String?, paneId: String?, binaryPath: String)
    /// herdr agent focus $paneId (with HERDR_SOCKET_PATH=$socket)
    case herdr(socket: String, paneId: String, binaryPath: String)
    /// zellij --session $sessionName action focus-pane-id $paneId
    case zellij(sessionName: String, paneId: String, binaryPath: String)
    /// tmux -S $socket select-window -t $paneId && tmux -S $socket select-pane -t $paneId
    case tmux(socket: String, paneId: String, binaryPath: String)
}

/// Resolve multiplexer focus from persisted or freshly resolved multiplexer info.
/// Returns nil when the primary strategy uses the Codex app route so
/// inherited terminal metadata cannot steal focus after the thread deep link.
func resolveMultiplexerFocus(
    session: SessionData,
    multiplexerOverride: MultiplexerInfo? = nil,
    primaryStrategy: FocusStrategy? = nil
) -> MultiplexerFocusStrategy? {
    if case .openURL(_, let restoreBundleID) = primaryStrategy,
       restoreBundleID == HostAppBundleID.codexDesktop {
        return nil
    }
    guard let mux = multiplexerOverride ?? session.terminal?.multiplexer else { return nil }
    switch mux {
    case .cmux(let socket, let workspaceId, let surfaceId, let paneId, let binaryPath):
        if cmuxNavigationURL(workspaceId: workspaceId, surfaceId: surfaceId, paneId: paneId) != nil {
            return nil
        }
        guard let binaryPath,
              cmuxFocusArguments(socket: socket, workspaceId: workspaceId, surfaceId: surfaceId, paneId: paneId) != nil
        else { return nil }
        return .cmux(
            socket: socket,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            paneId: paneId,
            binaryPath: binaryPath
        )
    case .herdr(let socket, let paneId, let binaryPath):
        guard let binaryPath else { return nil }
        return .herdr(socket: socket, paneId: paneId, binaryPath: binaryPath)
    case .zellij(let sessionName, let paneId, let binaryPath):
        guard let binaryPath else { return nil }
        return .zellij(sessionName: sessionName, paneId: paneId, binaryPath: binaryPath)
    case .tmux(let socket, let paneId, let binaryPath):
        guard let binaryPath else { return nil }
        return .tmux(socket: socket, paneId: paneId, binaryPath: binaryPath)
    }
}

// Failures are silently ignored — the emulator was already focused,
// which is better than nothing.
func executeMultiplexerFocus(_ strategy: MultiplexerFocusStrategy) {
    switch strategy {
    case .cmux(let socket, let workspaceId, let surfaceId, let paneId, let binaryPath):
        executeCmuxFocus(
            binaryPath: binaryPath, socket: socket, workspaceId: workspaceId,
            surfaceId: surfaceId, paneId: paneId
        )
    case .herdr(let socket, let paneId, let binaryPath):
        executeHerdrFocus(binaryPath: binaryPath, socket: socket, paneId: paneId)
    case .zellij(let sessionName, let paneId, let binaryPath):
        executeZellijFocus(binaryPath: binaryPath, sessionName: sessionName, paneId: paneId)
    case .tmux(let socket, let paneId, let binaryPath):
        executeTmuxFocus(binaryPath: binaryPath, socket: socket, paneId: paneId)
    }
}

private func executeHerdrFocus(binaryPath: String, socket: String, paneId: String) {
    runFocusCommand(
        binaryPath: binaryPath, arguments: ["agent", "focus", paneId],
        environment: ["HERDR_SOCKET_PATH": socket]
    )
}

// https://zellij.dev/documentation/controlling-zellij-through-cli
private func executeZellijFocus(binaryPath: String, sessionName: String, paneId: String) {
    runFocusCommand(binaryPath: binaryPath, arguments: ["--session", sessionName, "action", "focus-pane-id", paneId])
}

// https://man.openbsd.org/tmux.1
// select-window switches to the window containing the pane;
// select-pane then activates the specific pane within that window.
private func executeTmuxFocus(binaryPath: String, socket: String, paneId: String) {
    for cmd in [["select-window", "-t", paneId], ["select-pane", "-t", paneId]] {
        runFocusCommand(binaryPath: binaryPath, arguments: ["-S", socket] + cmd)
    }
}

/// Run a terminal CLI synchronously with its output discarded. Returns whether it
/// exited successfully; a launch failure counts as unsuccessful.
@discardableResult
func runFocusCommand(binaryPath: String, arguments: [String], environment: [String: String]? = nil) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)
    process.arguments = arguments
    if let environment { process.environment = environment }
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
