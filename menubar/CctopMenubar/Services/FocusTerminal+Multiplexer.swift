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

/// Resolve multiplexer focus from session info. Returns nil when no multiplexer is present.
/// Pure function — no side effects, fully testable.
func resolveMultiplexerFocus(session: Session) -> MultiplexerFocusStrategy? {
    resolveMultiplexerFocus(session: session, multiplexerOverride: nil)
}

/// Resolve multiplexer focus from persisted or freshly resolved multiplexer info.
func resolveMultiplexerFocus(session: Session, multiplexerOverride: MultiplexerInfo?) -> MultiplexerFocusStrategy? {
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
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)
    process.arguments = ["agent", "focus", paneId]
    process.environment = ["HERDR_SOCKET_PATH": socket]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {}
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
