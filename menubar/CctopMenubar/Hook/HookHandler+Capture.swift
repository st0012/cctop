import Foundation

// MARK: - Process tree and terminal capture

extension HookHandler {
    /// Walk up the process tree past shell intermediaries to find the Claude Code process.
    /// When invoked through run-hook.sh, getppid() returns the short-lived /bin/sh PID.
    /// We skip shell processes (sh, bash, zsh) to find the actual Claude Code process.
    static func getParentPID() -> UInt32 {
        let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash"]
        var pid = getppid()
        for _ in 0..<4 {
            guard let name = SessionData.processCommandName(pid: UInt32(pid)), shells.contains(name) else { break }
            let parentPid = parentPIDOf(pid)
            if parentPid <= 1 { break }
            pid = parentPid
        }
        return UInt32(pid)
    }

    private static func parentPIDOf(_ pid: pid_t) -> pid_t {
        SessionData.processInfo(pid: UInt32(pid))?.kp_eproc.e_ppid ?? 0
    }

    static func captureTerminalInfo(env: [String: String], process: any ProcessProbing) -> TerminalInfo {
        let program = env["TERM_PROGRAM"] ?? ""
        let sessionId = sanitizeTerminalSessionId(
            env["ITERM_SESSION_ID"] ?? env["KITTY_WINDOW_ID"]
        )
        let tty = env["TTY"] ?? process.controllingTTY()
        let bundleId = env["__CFBundleIdentifier"]
        // Remote-control socket for pane focusing.
        // Currently only Kitty (https://sw.kovidgoyal.net/kitty/remote-control/).
        // WezTerm also has a CLI (https://wezterm.org/cli/cli/index.html) — when
        // added, socket will likely become an enum keyed by terminal.
        let socket = env["KITTY_LISTEN_ON"]
        // binaryPaths is a map so it can grow to cover other socket-based terminals
        // (e.g. wezterm) without a schema change.
        let binaryPaths = socket.flatMap { _ in
            resolveBinaryPath(env: env, name: "kitty").map { ["kitty": $0] }
        }
        let multiplexer = captureMultiplexerInfo(env: env)
        return TerminalInfo(
            program: program, sessionId: sessionId, tty: tty,
            bundleId: bundleId, socket: socket, multiplexer: multiplexer,
            binaryPaths: binaryPaths
        )
    }

    /// Detect cmux, herdr, zellij, or tmux from env vars. Checks outer GUI multiplexers first.
    private static func captureMultiplexerInfo(env: [String: String]) -> MultiplexerInfo? {
        // cmux: CMUX_SOCKET_PATH + CMUX_WORKSPACE_ID + CMUX_SURFACE_ID.
        // CMUX_PANE_ID is accepted for same-session deep links when available, but
        // current cmux builds expose CMUX_SURFACE_ID as the documented focus target.
        let cmuxSurfaceId = sanitizeTerminalSessionId(env["CMUX_SURFACE_ID"])
        if let socket = env["CMUX_SOCKET_PATH"], !socket.isEmpty,
           let workspaceId = sanitizeTerminalSessionId(env["CMUX_WORKSPACE_ID"]),
           let surfaceId = cmuxSurfaceId {
            let paneId = sanitizeTerminalSessionId(env["CMUX_PANE_ID"])
            let path = resolveBinaryPath(env: env, name: "cmux")
            return .cmux(
                socket: socket, workspaceId: workspaceId,
                surfaceId: surfaceId, paneId: paneId, binaryPath: path
            )
        }
        // Older or experimental cmux contexts may expose a pane id without a surface id.
        if let socket = env["CMUX_SOCKET_PATH"], !socket.isEmpty,
           let workspaceId = sanitizeTerminalSessionId(env["CMUX_WORKSPACE_ID"]),
           let paneId = sanitizeTerminalSessionId(env["CMUX_PANE_ID"]) {
            let path = resolveBinaryPath(env: env, name: "cmux")
            return .cmux(
                socket: socket, workspaceId: workspaceId,
                surfaceId: nil, paneId: paneId, binaryPath: path
            )
        }
        // herdr: HERDR_SOCKET_PATH + HERDR_PANE_ID
        if let socket = env["HERDR_SOCKET_PATH"], !socket.isEmpty,
           let paneId = sanitizeTerminalSessionId(env["HERDR_PANE_ID"]) {
            let path = resolveBinaryPath(env: env, name: "herdr")
            return .herdr(socket: socket, paneId: paneId, binaryPath: path)
        }
        // zellij: ZELLIJ_SESSION_NAME + ZELLIJ_PANE_ID
        if let sessionName = sanitizeTerminalSessionId(env["ZELLIJ_SESSION_NAME"]),
           let paneId = sanitizeTerminalSessionId(env["ZELLIJ_PANE_ID"]) {
            let path = resolveBinaryPath(env: env, name: "zellij")
            return .zellij(sessionName: sessionName, paneId: paneId, binaryPath: path)
        }
        // tmux: $TMUX = "socket_path,pid,session_index", $TMUX_PANE = "%N"
        if let tmux = env["TMUX"],
           let paneId = sanitizeTerminalSessionId(env["TMUX_PANE"]),
           let socket = tmux.split(separator: ",").first.map(String.init),
           !socket.isEmpty {
            let path = resolveBinaryPath(env: env, name: "tmux")
            return .tmux(socket: socket, paneId: paneId, binaryPath: path)
        }
        return nil
    }

    /// Validate terminal session IDs to prevent injection via env vars.
    /// Only allows alphanumeric, hyphens, colons, periods, at-signs, underscores, and percent
    /// (covers iTerm2, Kitty, cmux, herdr, zellij, and tmux formats).
    private static func sanitizeTerminalSessionId(_ value: String?) -> String? {
        guard let value, !value.isEmpty,
              value.range(of: #"^[0-9a-zA-Z:.@_%-]+$"#, options: .regularExpression) != nil
        else { return nil }
        return value
    }

    /// Resolve absolute path for a CLI binary by searching $PATH.
    private static func resolveBinaryPath(env: [String: String], name: String) -> String? {
        guard let pathEnv = env["PATH"] else { return nil }
        let fm = FileManager.default
        for dir in pathEnv.split(separator: ":") {
            let fullPath = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            if fm.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }

    /// Walk up the process tree to find the first ancestor with a controlling terminal.
    /// The hook subprocess itself has no tty (stdin is piped JSON), but ancestor
    /// processes (claude, shell) do.
    static func findTTY() -> String? {
        var pid = getppid()
        for _ in 0..<6 {
            if pid <= 1 { break }
            if let tty = ttyOfPID(pid) { return tty }
            pid = parentPIDOf(pid)
        }
        return nil
    }

    private static func ttyOfPID(_ pid: pid_t) -> String? {
        guard let info = SessionData.processInfo(pid: UInt32(pid)) else { return nil }
        let tdev = info.kp_eproc.e_tdev
        guard tdev != UInt32.max, let name = devname(tdev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }
}

// MARK: - Git Branch

func getCurrentBranch(cwd: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["branch", "--show-current"]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "unknown" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let branch = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return branch.isEmpty ? "unknown" : branch
    } catch {
        return "unknown"
    }
}
