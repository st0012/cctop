import Foundation

private let cmuxEnvironmentKeys = [
    "CMUX_SOCKET_PATH",
    "CMUX_WORKSPACE_ID",
    "CMUX_TAB_ID",
    "CMUX_SURFACE_ID",
    "CMUX_PANEL_ID",
    "CMUX_PANE_ID",
    "CMUX_CLAUDE_HOOK_CMUX_BIN",
    "CMUX_BUNDLED_CLI_PATH",
    "PATH"
]

/// cmux handles cmux://workspace/<workspace>/surface/<surface> by locating the
/// owning window, focusing it, then focusing the requested surface.
/// Source: https://github.com/manaflow-ai/cmux/blob/main/Sources/CmuxSSHURLRequest.swift
func cmuxNavigationURL(multiplexer: MultiplexerInfo?) -> URL? {
    guard case .cmux(_, let workspaceId, let surfaceId, let paneId, _) = multiplexer else {
        return nil
    }
    return cmuxNavigationURL(workspaceId: workspaceId, surfaceId: surfaceId, paneId: paneId)
}

func cmuxNavigationURL(workspaceId: String, surfaceId: String?, paneId: String?) -> URL? {
    guard let workspaceUUID = UUID(uuidString: workspaceId) else { return nil }
    if let surfaceUUID = surfaceId.flatMap(UUID.init(uuidString:)) {
        return URL(string: "cmux://workspace/\(workspaceUUID.uuidString)/surface/\(surfaceUUID.uuidString)")
    }
    if let paneUUID = paneId.flatMap(UUID.init(uuidString:)) {
        return URL(string: "cmux://workspace/\(workspaceUUID.uuidString)/pane/\(paneUUID.uuidString)")
    }
    return nil
}

// https://cmux.com/docs/api
func cmuxFocusArguments(socket: String, workspaceId: String, surfaceId: String?, paneId: String?) -> [String]? {
    guard let surfaceId else { return nil }
    return ["--socket", socket, "focus-surface", "--workspace", workspaceId, "--surface", surfaceId]
}

func resolveCmuxLiveMultiplexer(session: Session) -> MultiplexerInfo? {
    resolveCmuxLiveMultiplexer(session: session, environmentLookup: cmuxEnvironmentForProcess(pid:))
}

func resolveCmuxLiveMultiplexer(
    session: Session,
    environmentLookup: (UInt32) -> [String: String]?
) -> MultiplexerInfo? {
    guard session.terminal?.multiplexer == nil,
          session.trustedHostApp == .cmux,
          let pid = session.pid,
          let env = environmentLookup(pid)
    else { return nil }
    return cmuxMultiplexerInfo(env: env)
}

func cmuxMultiplexerInfo(env: [String: String]) -> MultiplexerInfo? {
    guard let socket = env["CMUX_SOCKET_PATH"], !socket.isEmpty,
          let workspaceId = sanitizeCmuxIdentifier(env["CMUX_WORKSPACE_ID"] ?? env["CMUX_TAB_ID"])
    else { return nil }

    let surfaceId = sanitizeCmuxIdentifier(env["CMUX_SURFACE_ID"] ?? env["CMUX_PANEL_ID"])
    let paneId = sanitizeCmuxIdentifier(env["CMUX_PANE_ID"])
    guard surfaceId != nil || paneId != nil else { return nil }

    return .cmux(
        socket: socket,
        workspaceId: workspaceId,
        surfaceId: surfaceId,
        paneId: paneId,
        binaryPath: cmuxBinaryPath(env: env)
    )
}

func cmuxEnvironmentForProcess(pid: UInt32) -> [String: String]? {
    guard let environmentText = cmuxProcessEnvironmentText(pid: pid) else { return nil }
    let env = extractCmuxEnvironment(from: environmentText)
    return env.isEmpty ? nil : env
}

func extractCmuxEnvironment(from text: String) -> [String: String] {
    var env: [String: String] = [:]
    for key in cmuxEnvironmentKeys {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"(^|\s)"# + escapedKey + #"=([^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let valueRange = Range(match.range(at: 2), in: text)
        else { continue }
        let value = String(text[valueRange])
        if !value.isEmpty {
            env[key] = value
        }
    }
    return env
}

private func cmuxProcessEnvironmentText(pid: UInt32) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["eww", "-p", String(pid)]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }

    guard process.terminationStatus == 0 else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

private func cmuxBinaryPath(env: [String: String]) -> String? {
    for key in ["CMUX_CLAUDE_HOOK_CMUX_BIN", "CMUX_BUNDLED_CLI_PATH"] {
        if let path = executablePath(env[key]) {
            return path
        }
    }
    guard let pathEnv = env["PATH"] else { return nil }
    for dir in pathEnv.split(separator: ":") {
        let fullPath = URL(fileURLWithPath: String(dir)).appendingPathComponent("cmux").path
        if let path = executablePath(fullPath) {
            return path
        }
    }
    return nil
}

private func executablePath(_ path: String?) -> String? {
    guard let path, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
        return nil
    }
    return path
}

private func sanitizeCmuxIdentifier(_ value: String?) -> String? {
    guard let value, !value.isEmpty,
          value.range(of: #"^[0-9a-zA-Z:.@_%-]+$"#, options: .regularExpression) != nil
    else { return nil }
    return value
}

func executeCmuxFocus(
    binaryPath: String,
    socket: String,
    workspaceId: String,
    surfaceId: String?,
    paneId: String?
) {
    guard let arguments = cmuxFocusArguments(
        socket: socket,
        workspaceId: workspaceId,
        surfaceId: surfaceId,
        paneId: paneId
    ) else { return }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {}
}
