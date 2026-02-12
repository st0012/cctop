import Foundation

enum HookHandler {
    private static let maxToolDetailLen = 120
    private static let noPIDMaxAge: TimeInterval = 24 * 3600

    static func handleHook(hookName: String, input: HookInput) throws {
        let event = HookEvent.parse(hookName: hookName, notificationType: input.notificationType)

        if event == .sessionEnd { return }

        let sessionsDir = Config.sessionsDir()
        let safeId = Session.sanitizeSessionId(raw: input.sessionId)
        let label = HookLogger.sessionLabel(cwd: input.cwd, sessionId: safeId)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("\(safeId).json")

        let branch = getCurrentBranch(cwd: input.cwd)
        let terminal = captureTerminalInfo()

        var session: Session
        if FileManager.default.fileExists(atPath: sessionPath),
           let existing = try? Session.fromFile(path: sessionPath) {
            session = existing
        } else {
            session = Session(sessionId: safeId, projectPath: input.cwd, branch: branch, terminal: terminal)
        }

        if session.pid == nil {
            session.pid = getParentPID()
        }

        let oldStatus = session.status.rawValue
        let newStatus = Transition.forEvent(session.status, event: event)

        if let newStatus {
            session.status = newStatus
        }

        session.lastActivity = Date()
        session.branch = branch
        session.terminal = terminal
        if event == .sessionStart || event == .userPromptSubmit {
            session.sessionName = SessionNameLookup.lookupSessionName(transcriptPath: input.transcriptPath, sessionId: input.sessionId)
        }

        applySideEffects(event: event, session: &session, input: input, sessionsDir: sessionsDir, safeId: safeId)

        let suffix = newStatus == nil ? " (preserved)" : ""
        let transition = "\(oldStatus) -> \(session.status.rawValue)\(suffix)"
        HookLogger.appendHookLog(
            sessionId: safeId,
            event: hookName,
            label: label,
            transition: transition
        )

        try session.writeToFile(path: sessionPath)
    }

    private static func clearToolState(_ session: inout Session) {
        session.lastTool = nil
        session.lastToolDetail = nil
        session.notificationMessage = nil
    }

    private static func applySideEffects(
        event: HookEvent, session: inout Session, input: HookInput,
        sessionsDir: String, safeId: String
    ) {
        switch event {
        case .sessionStart:
            clearToolState(&session)
            let pid = getParentPID()
            session.pid = pid
            cleanupSessionsForProject(sessionsDir: sessionsDir, projectPath: input.cwd, currentSessionId: safeId)
            cleanupSessionsWithPID(sessionsDir: sessionsDir, pid: pid, currentSessionId: safeId)

        case .userPromptSubmit:
            clearToolState(&session)
            if let prompt = input.prompt {
                session.lastPrompt = prompt
            }

        case .preToolUse:
            if let toolName = input.toolName {
                session.lastTool = toolName
                session.lastToolDetail = extractToolDetail(toolName: toolName, toolInput: input.toolInput)
            }

        case .permissionRequest:
            let msg = input.title ?? input.toolName.map { tool in
                let detail = extractToolDetail(toolName: tool, toolInput: input.toolInput)
                if let detail { return "\(tool): \(detail)" }
                return tool
            }
            session.notificationMessage = msg
            session.lastTool = nil
            session.lastToolDetail = nil

        case .notificationIdle, .notificationPermission, .notificationOther:
            session.lastTool = nil
            session.lastToolDetail = nil
            if let msg = input.message {
                session.notificationMessage = msg
            }

        case .stop:
            clearToolState(&session)

        case .preCompact, .postToolUse, .sessionEnd, .unknown:
            break
        }
    }

    // MARK: - Helpers

    /// Walk up the process tree past shell intermediaries to find the Claude Code process.
    /// When invoked through run-hook.sh, getppid() returns the short-lived /bin/sh PID.
    /// We skip shell processes (sh, bash, zsh) to find the actual Claude Code process.
    static func getParentPID() -> UInt32 {
        let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash"]
        var pid = getppid()
        for _ in 0..<4 {
            let name = processName(pid)
            if !shells.contains(name) { break }
            let parentPid = parentPIDOf(pid)
            if parentPid <= 1 { break }
            pid = parentPid
        }
        return UInt32(pid)
    }

    private static func procInfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private static func parentPIDOf(_ pid: pid_t) -> pid_t {
        procInfo(pid)?.kp_eproc.e_ppid ?? 0
    }

    private static func processName(_ pid: pid_t) -> String {
        guard var info = procInfo(pid) else { return "" }
        return withUnsafePointer(to: &info.kp_proc.p_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { cStr in
                String(cString: cStr)
            }
        }
    }

    static func captureTerminalInfo() -> TerminalInfo {
        let program = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? ""
        let sessionId = ProcessInfo.processInfo.environment["ITERM_SESSION_ID"]
            ?? ProcessInfo.processInfo.environment["KITTY_WINDOW_ID"]
        let tty = ProcessInfo.processInfo.environment["TTY"]
            ?? findTTY()
        return TerminalInfo(program: program, sessionId: sessionId, tty: tty)
    }

    /// Walk up the process tree to find the first ancestor with a controlling terminal.
    /// The hook subprocess itself has no tty (stdin is piped JSON), but ancestor
    /// processes (claude, shell) do.
    private static func findTTY() -> String? {
        var pid = getppid()
        for _ in 0..<6 {
            if pid <= 1 { break }
            if let tty = ttyOfPID(pid) { return tty }
            pid = parentPIDOf(pid)
        }
        return nil
    }

    private static func ttyOfPID(_ pid: pid_t) -> String? {
        guard let info = procInfo(pid) else { return nil }
        let tdev = info.kp_eproc.e_tdev
        guard tdev != UInt32.max, let name = devname(tdev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    static func extractToolDetail(toolName: String, toolInput: [String: String]?) -> String? {
        guard let toolInput else { return nil }

        let field: String
        switch toolName {
        case "Bash": field = "command"
        case "Edit", "Write", "Read": field = "file_path"
        case "Grep", "Glob": field = "pattern"
        case "WebFetch": field = "url"
        case "WebSearch": field = "query"
        case "Task": field = "description"
        default: return nil
        }

        guard let value = toolInput[field], !value.isEmpty else { return nil }

        if value.count > maxToolDetailLen {
            return String(value.prefix(maxToolDetailLen - 3)) + "..."
        }
        return value
    }

    static func getCurrentBranch(cwd: String) -> String {
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
            let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return branch.isEmpty ? "unknown" : branch
        } catch {
            return "unknown"
        }
    }

    // MARK: - Cleanup

    static func cleanupSessionsWithPID(sessionsDir: String, pid: UInt32, currentSessionId: String) {
        forEachSession(in: sessionsDir) { path, session in
            if session.pid == pid && session.sessionId != currentSessionId {
                removeSession(at: path, sessionId: session.sessionId)
            }
        }
    }

    static func cleanupSessionsForProject(sessionsDir: String, projectPath: String, currentSessionId: String) {
        forEachSession(in: sessionsDir) { path, session in
            guard session.projectPath == projectPath, session.sessionId != currentSessionId else { return }

            let isStale: Bool
            if let pid = session.pid {
                isStale = !isPIDAlive(pid)
            } else {
                isStale = -session.lastActivity.timeIntervalSinceNow > noPIDMaxAge
            }

            if isStale {
                removeSession(at: path, sessionId: session.sessionId)
            }
        }
    }

    private static func forEachSession(in dir: String, body: (String, Session) -> Void) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for entry in entries where entry.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(entry)
            guard let session = try? Session.fromFile(path: path) else { continue }
            body(path, session)
        }
    }

    private static func removeSession(at path: String, sessionId: String) {
        try? FileManager.default.removeItem(atPath: path)
        HookLogger.cleanupSessionLog(sessionId: sessionId)
    }

    private static func isPIDAlive(_ pid: UInt32) -> Bool {
        kill(Int32(pid), 0) == 0 || errno == EPERM
    }
}
