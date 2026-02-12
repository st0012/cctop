import Foundation

enum HookHandler {
    /// Maximum length for extracted tool detail strings.
    private static let maxToolDetailLen = 120

    /// Maximum age for sessions without a PID before they are cleaned up.
    private static let noPIDMaxAge: TimeInterval = 24 * 3600

    /// Handle a hook event by updating or creating the session file.
    static func handleHook(hookName: String, input: HookInput) throws {
        let event = HookEvent.parse(hookName: hookName, notificationType: input.notificationType)

        // SessionEnd is a no-op (PID-based liveness detection handles cleanup)
        if event == .sessionEnd { return }

        let sessionsDir = Config.sessionsDir()
        let safeId = Session.sanitizeSessionId(raw: input.sessionId)
        let label = HookLogger.sessionLabel(cwd: input.cwd, sessionId: safeId)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("\(safeId).json")

        let branch = getCurrentBranch(cwd: input.cwd)
        let terminal = captureTerminalInfo()

        // Load existing session or create new one
        var session: Session
        if FileManager.default.fileExists(atPath: sessionPath),
           let existing = try? Session.fromFile(path: sessionPath) {
            session = existing
        } else {
            session = Session(sessionId: safeId, projectPath: input.cwd, branch: branch, terminal: terminal)
        }

        // Backfill PID if missing
        if session.pid == nil {
            session.pid = getParentPID()
        }

        let oldStatus = session.status.asStr

        // Use centralized transition table
        let statusPreserved = Transition.forEvent(session.status, event: event) == nil
        if let newStatus = Transition.forEvent(session.status, event: event) {
            session.status = newStatus
        }

        session.lastActivity = Date()
        session.branch = branch
        session.terminal = terminal

        // Apply side effects per hook event
        switch event {
        case .sessionStart:
            session.lastTool = nil
            session.lastToolDetail = nil
            session.notificationMessage = nil

            let pid = getParentPID()
            session.pid = pid

            cleanupSessionsForProject(sessionsDir: sessionsDir, projectPath: input.cwd, currentSessionId: safeId)
            cleanupSessionsWithPID(sessionsDir: sessionsDir, pid: pid, currentSessionId: safeId)

        case .userPromptSubmit:
            session.lastTool = nil
            session.lastToolDetail = nil
            session.notificationMessage = nil
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
            session.lastTool = nil
            session.lastToolDetail = nil
            session.notificationMessage = nil

        case .preCompact:
            break

        case .postToolUse, .sessionEnd, .unknown:
            break
        }

        let note = statusPreserved ? "preserved" : ""
        HookLogger.appendHookLog(
            sessionId: safeId,
            event: hookName,
            label: label,
            oldStatus: oldStatus,
            newStatus: session.status.asStr,
            note: note
        )

        try session.writeToFile(path: sessionPath)
    }

    // MARK: - Helpers

    static func getParentPID() -> UInt32 {
        UInt32(getppid())
    }

    static func captureTerminalInfo() -> TerminalInfo {
        let program = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? ""
        let sessionId = ProcessInfo.processInfo.environment["ITERM_SESSION_ID"]
            ?? ProcessInfo.processInfo.environment["KITTY_WINDOW_ID"]
        let tty = ProcessInfo.processInfo.environment["TTY"]
        return TerminalInfo(program: program, sessionId: sessionId, tty: tty)
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
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return }

        for entry in entries {
            guard entry.hasSuffix(".json") else { continue }
            let path = (sessionsDir as NSString).appendingPathComponent(entry)
            guard let session = try? Session.fromFile(path: path) else { continue }
            if session.pid == pid && session.sessionId != currentSessionId {
                try? fm.removeItem(atPath: path)
                HookLogger.cleanupSessionLog(sessionId: session.sessionId)
            }
        }
    }

    static func cleanupSessionsForProject(sessionsDir: String, projectPath: String, currentSessionId: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return }

        for entry in entries {
            guard entry.hasSuffix(".json") else { continue }
            let path = (sessionsDir as NSString).appendingPathComponent(entry)
            guard let session = try? Session.fromFile(path: path) else { continue }
            if session.projectPath != projectPath || session.sessionId == currentSessionId {
                continue
            }

            let shouldRemove: Bool
            if let pid = session.pid {
                shouldRemove = !isPIDAlive(pid)
            } else {
                shouldRemove = -session.lastActivity.timeIntervalSinceNow > noPIDMaxAge
            }

            if shouldRemove {
                try? fm.removeItem(atPath: path)
                HookLogger.cleanupSessionLog(sessionId: session.sessionId)
            }
        }
    }

    private static func isPIDAlive(_ pid: UInt32) -> Bool {
        if kill(Int32(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}
