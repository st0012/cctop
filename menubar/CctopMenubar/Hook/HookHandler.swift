import Foundation

enum HookHandler {
    private static let maxToolDetailLen = 120
    // MIGRATION(v0.6.0): Remove after all users have migrated to PID-keyed sessions.
    private static let noPIDMaxAge: TimeInterval = 300

    static func handleHook(hookName: String, input: HookInput) throws {
        let event = HookEvent.parse(hookName: hookName, notificationType: input.notificationType)

        if event == .sessionEnd { return }

        let sessionsDir = Config.sessionsDir()
        let safeId = Session.sanitizeSessionId(raw: input.sessionId)
        let pid = getParentPID()
        let label = HookLogger.sessionLabel(cwd: input.cwd, sessionId: safeId)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("\(pid).json")

        let branch = getCurrentBranch(cwd: input.cwd)
        let terminal = captureTerminalInfo()
        let startTime = Session.processStartTime(pid: pid)

        let freshSession = Session(sessionId: safeId, projectPath: input.cwd, branch: branch, terminal: terminal)
        var session = loadOrCreateSession(
            path: sessionPath, event: event, startTime: startTime, fresh: freshSession
        )

        session.pid = pid
        session.pidStartTime = startTime

        let oldStatus = session.status.rawValue
        let newStatus = Transition.forEvent(session.status, event: event)

        if let newStatus {
            session.status = newStatus
        }

        // Skip lastActivity update for late notificationPermission — the PermissionRequest
        // already set it, and we need the original timestamp for child-process-start-time
        // comparison in the menubar app.
        if event != .notificationPermission {
            session.lastActivity = Date()
        }
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
            session.workspaceFile = Session.findWorkspaceFile(in: input.cwd)
            cleanupSessionsForProject(sessionsDir: sessionsDir, projectPath: input.cwd, currentPid: session.pid)

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
            // Keep lastTool/lastToolDetail from the preceding PreToolUse — when the
            // delayed Notification transitions to .working, the card can show what tool is running.

        case .notificationIdle, .notificationOther:
            session.lastTool = nil
            session.lastToolDetail = nil
            if let msg = input.message {
                session.notificationMessage = msg
            }

        case .notificationPermission:
            // PermissionRequest already handles side effects (clears tool state, sets notificationMessage).
            // The Notification fires ~6s later and would clobber parallel tool state.
            break

        case .stop:
            clearToolState(&session)

        case .preCompact, .postToolUse, .sessionEnd, .unknown:
            break
        }
    }

    // MARK: - Session Loading

    private static func loadOrCreateSession(
        path: String, event: HookEvent, startTime: TimeInterval?, fresh: Session
    ) -> Session {
        guard FileManager.default.fileExists(atPath: path),
              let existing = try? Session.fromFile(path: path) else {
            return fresh
        }
        // PID reuse: different process start time means a new process reused this PID
        if event == .sessionStart,
           let storedStart = existing.pidStartTime,
           let currentStart = startTime,
           abs(storedStart - currentStart) > 1.0 {
            return fresh
        }
        // Same process but CC assigned a new session_id (e.g. resume) — carry over state
        guard existing.sessionId == fresh.sessionId else {
            return existing.withSessionId(fresh.sessionId, branch: fresh.branch, terminal: fresh.terminal)
        }
        return existing
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
        var program = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? ""
        // JetBrains IDEs don't set TERM_PROGRAM; fall back to __CFBundleIdentifier
        if program.isEmpty {
            program = ProcessInfo.processInfo.environment["__CFBundleIdentifier"] ?? ""
        }
        let sessionId = sanitizeTerminalSessionId(
            ProcessInfo.processInfo.environment["ITERM_SESSION_ID"]
            ?? ProcessInfo.processInfo.environment["KITTY_WINDOW_ID"]
        )
        let tty = ProcessInfo.processInfo.environment["TTY"]
            ?? findTTY()
        return TerminalInfo(program: program, sessionId: sessionId, tty: tty)
    }

    /// Validate terminal session IDs to prevent injection via env vars.
    /// Only allows alphanumeric, hyphens, colons, and periods (covers iTerm2 and Kitty formats).
    private static func sanitizeTerminalSessionId(_ value: String?) -> String? {
        guard let value, !value.isEmpty,
              value.range(of: #"^[0-9a-zA-Z:.@_-]+$"#, options: .regularExpression) != nil
        else { return nil }
        return value
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
        switch toolName.lowercased() {
        case "bash": field = "command"
        case "edit", "write", "read": field = "file_path"
        case "grep", "glob": field = "pattern"
        case "webfetch": field = "url"
        case "websearch": field = "query"
        case "task": field = "description"
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

    static func cleanupSessionsForProject(sessionsDir: String, projectPath: String, currentPid: UInt32?) {
        forEachSession(in: sessionsDir) { path, session in
            guard session.projectPath == projectPath, session.pid != currentPid else { return }

            let isStale: Bool
            if let pid = session.pid {
                if !isPIDAlive(pid) {
                    isStale = true
                } else if let storedStart = session.pidStartTime,
                          let currentStart = Session.processStartTime(pid: pid),
                          abs(storedStart - currentStart) > 1.0 {
                    isStale = true  // PID reused by a different process
                } else {
                    isStale = false
                }
            } else {
                // MIGRATION(v0.6.0): Remove no-PID branch after all users have migrated.
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
