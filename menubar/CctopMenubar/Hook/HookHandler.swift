// swiftlint:disable file_length
import Foundation

private let maxToolDetailLen = 120

enum HookHandler {
    // MIGRATION(v0.6.0): Remove after all users have migrated to PID-keyed sessions.
    private static let noPIDMaxAge: TimeInterval = 300

    static func handleHook(hookName: String, input: HookInput, deps: HookDependencies = .live) throws {
        let event = HookEvent.parse(hookName: hookName, notificationType: input.notificationType)

        if event == .sessionEnd {
            handleSessionEnd(hookName: hookName, input: input, deps: deps)
            return
        }

        let sessionsDir = deps.sessionsDir()
        let safeId = Session.sanitizeSessionId(raw: input.sessionId)
        let pid = deps.process.parentPID()
        let label = HookLogger.sessionLabel(cwd: input.cwd, sessionId: safeId)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent(sessionFileName(input: input, pid: pid, safeSessionId: safeId))

        let branch = deps.currentBranch(input.cwd)
        let terminal = captureTerminalInfo(env: deps.environment(), process: deps.process)
        let startTime = deps.process.startTime(pid: pid)

        // Capture-side diagnostic (issue #155 P5): the parent walk should land on this
        // harness's own process. A foreign-harness PID means liveness for this file will
        // track the wrong process — log it so the adoption path can be confirmed in the field.
        if let parentComm = deps.process.commandName(pid: pid),
           Session.isForeignHarnessComm(parentComm, source: input.resolvedHarnessName) {
            deps.logger.appendHookLog(
                sessionId: safeId, event: hookName, label: label,
                transition: "warning: parent pid \(pid) is '\(parentComm)', a foreign harness"
            )
        }

        // Lock the session file for the entire read-modify-write cycle.
        // Without this, concurrent hook processes (e.g. SubagentStart + PreToolUse
        // firing simultaneously) race: both read the old file, apply changes
        // independently, and the last writer wins — clobbering the first writer's changes.
        try withSessionLock(sessionPath: sessionPath, onError: deps.logger.logError) {
            let freshSession = Session(sessionId: safeId, projectPath: input.cwd, branch: branch, terminal: terminal)
            let loaded = loadOrCreateSession(
                path: sessionPath, event: event, startTime: startTime, fresh: freshSession
            )
            var session = loaded.session
            let isNewSessionFile = loaded.isNewSessionFile

            session.pid = pid
            session.pidStartTime = startTime

            let (oldStatus, newStatus) = applyTransition(&session, event: event, input: input, branch: branch, terminal: terminal)
            applySessionName(&session, event: event, input: input, names: deps.names)
            applySideEffects(event: event, session: &session, input: input, sessionsDir: sessionsDir, safeId: safeId)
            if input.isSubagentSession == true { session.isSubagentSession = true }
            if session.shouldAutoHide { session.hidden = true }
            session.markWrittenByHook(version: Config.hookVersion, isNewSessionFile: isNewSessionFile)

            let suffix = newStatus == nil ? " (preserved)" : ""
            deps.logger.appendHookLog(
                sessionId: safeId, event: hookName, label: label,
                transition: "\(oldStatus) -> \(session.status.rawValue)\(suffix)"
            )
            try session.writeToFile(path: sessionPath)
        }

        // Cleanup runs outside the lock — it scans all session files and makes
        // sysctl calls per file, which would unnecessarily hold the lock.
        if event == .sessionStart {
            cleanupSessionsForProject(
                sessionsDir: sessionsDir, projectPath: input.cwd, currentPid: pid,
                process: deps.process, logger: deps.logger
            )
        }
    }

    private static func clearToolState(_ session: inout Session) {
        session.lastTool = nil
        session.lastToolDetail = nil
        session.notificationMessage = nil
    }
    private static func applySubagentEvent(event: HookEvent, session: inout Session, input: HookInput) {
        switch event {
        case .subagentStart:
            guard let agentId = input.agentId, let agentType = input.agentType else { return }
            if session.activeSubagents == nil { session.activeSubagents = [] }
            if !session.activeSubagents!.contains(where: { $0.agentId == agentId }) {
                session.activeSubagents!.append(
                    SubagentInfo(agentId: agentId, agentType: agentType, startedAt: Date())
                )
            }
        case .subagentStop:
            if let agentId = input.agentId {
                session.activeSubagents?.removeAll { $0.agentId == agentId }
            }
        default:
            break
        }
    }

    /// Apply status transition and update session metadata. Returns (oldStatus, newStatus).
    private static func applyTransition(
        _ session: inout Session, event: HookEvent, input: HookInput,
        branch: String, terminal: TerminalInfo
    ) -> (String, SessionStatus?) {
        let oldStatus = session.status.rawValue
        let newStatus = Transition.forEvent(session.status, event: event)
        if let newStatus { session.status = newStatus }
        // Skip lastActivity for notificationPermission — PermissionRequest already set it,
        // and the menubar app needs the original timestamp for child-process-start-time comparison.
        if event != .notificationPermission { session.lastActivity = Date() }
        if Transition.clearsInactiveMarkers(event: event) {
            session.endedAt = nil
            session.disconnectedAt = nil
        }
        session.branch = branch; session.terminal = terminal
        // MIGRATION(harness_name): The session JSON file still uses the `source` key.
        // Renaming the JSON key would require a reader-side migration in SessionManager.
        // Do that in a future PR once `harness_name` is settled.
        if let harness = input.resolvedHarnessName { session.source = harness }
        return (oldStatus, newStatus)
    }

    /// Update the user-visible session name. Runs right after applyTransition, once
    /// source/terminal are current, since the lookup strategy depends on both.
    private static func applySessionName(
        _ session: inout Session, event: HookEvent, input: HookInput, names: any SessionNameResolving
    ) {
        if let name = input.sessionName {
            session.sessionName = name
        } else if event == .sessionStart || event == .userPromptSubmit || event == .stop
                    || (session.source == "codex" && session.sessionName == nil) {
            // Only overwrite when the lookup succeeds (preserve-on-fail). Re-run on prompt
            // boundaries (and .stop, for Claude Code) to catch renames. Codex additionally
            // re-runs on ANY event while the name is still missing: it never fires .stop and
            // titles its thread mid-turn, and its index is a single small file — so this
            // fills the name within seconds, without a per-tool-call directory scan.
            //
            // Each harness exposes the title from a different local source:
            //   - codex:          ~/.codex/session_index.jsonl (keyed by session_id)
            //   - Claude Desktop: claude-code-sessions/**/local_*.json (keyed by cliSessionId);
            //                     Desktop never writes a `custom-title` to the CC transcript
            //   - terminal CC:    the transcript JSONL `custom-title` entry
            let lookedUp: String?
            if session.source == "codex" {
                lookedUp = names.codexThreadName(sessionId: input.sessionId)
            } else if session.terminal?.bundleId == HostAppBundleID.claudeDesktop {
                lookedUp = names.claudeDesktopTitle(cliSessionId: input.sessionId)
            } else {
                lookedUp = names.transcriptSessionName(
                    transcriptPath: input.transcriptPath, sessionId: input.sessionId
                )
            }
            if let name = lookedUp {
                session.sessionName = name
            }
        }
    }

    private static func applySideEffects(
        event: HookEvent, session: inout Session, input: HookInput,
        sessionsDir: String, safeId: String
    ) {
        switch event {
        case .sessionStart:
            clearToolState(&session)
            session.activeSubagents = []
            session.workspaceFile = Session.findWorkspaceFile(in: input.cwd)
        case .userPromptSubmit:
            clearToolState(&session)
            if let prompt = input.prompt { session.lastPrompt = prompt }
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
            session.lastTool = nil; session.lastToolDetail = nil
            if let msg = input.message { session.notificationMessage = msg }
        case .stop:
            clearToolState(&session)
        case .postToolUseFailure:
            if let error = input.error { session.notificationMessage = error }
        case .subagentStart, .subagentStop:
            applySubagentEvent(event: event, session: &session, input: input)

        case .sessionError:
            session.notificationMessage = input.error ?? input.message

        // notificationPermission: PermissionRequest already handles side effects; Notification fires ~6s later.
        case .notificationPermission, .postCompact, .preCompact, .postToolUse, .sessionEnd, .unknown:
            break
        }
    }

    // MARK: - Session Loading

    private static func loadOrCreateSession(
        path: String, event: HookEvent, startTime: TimeInterval?, fresh: Session
    ) -> (session: Session, isNewSessionFile: Bool) {
        guard FileManager.default.fileExists(atPath: path),
              let existing = try? Session.fromFile(path: path) else {
            return (fresh, true)
        }
        // PID reuse: different process start time means a new process reused this PID
        if event == .sessionStart,
           let storedStart = existing.pidStartTime,
           let currentStart = startTime,
           abs(storedStart - currentStart) > 1.0 {
            return (fresh, true)
        }
        // Same PID, different session_id — a PID-keyed source (opencode/pi) reused the
        // process for a new conversation. Drop conversation-specific state (project, name,
        // prompt, tools, etc.) and carry over only PID liveness metadata. (Codex no longer
        // reaches this: it is keyed by session_id, so each conversation has its own file.)
        guard existing.sessionId == fresh.sessionId else {
            var carried = fresh
            carried.pid = existing.pid
            carried.pidStartTime = existing.pidStartTime
            return (carried, true)
        }
        return (existing, false)
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
        // p_comm stores MAXCOMLEN chars + NUL; the +1 keeps a full-length comm's
        // terminator inside the rebound region.
        return withUnsafePointer(to: &info.kp_proc.p_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { cStr in
                String(cString: cStr)
            }
        }
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

    /// Detect zellij or tmux from env vars. Checks zellij first, then tmux.
    private static func captureMultiplexerInfo(env: [String: String]) -> MultiplexerInfo? {
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
    /// Only allows alphanumeric, hyphens, colons, periods, at-signs, underscores, and percent (covers iTerm2, Kitty, and tmux formats).
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
        guard let info = procInfo(pid) else { return nil }
        let tdev = info.kp_eproc.e_tdev
        guard tdev != UInt32.max, let name = devname(tdev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

}

extension HookHandler {
    // MARK: - Cleanup

    private static func handleSessionEnd(hookName: String, input: HookInput, deps: HookDependencies) {
        let pid = deps.process.parentPID()
        let safeId = Session.sanitizeSessionId(raw: input.sessionId)
        let sessionsDir = deps.sessionsDir()
        let primaryPath = (sessionsDir as NSString).appendingPathComponent(sessionFileName(input: input, pid: pid, safeSessionId: safeId))
        let label = HookLogger.sessionLabel(cwd: input.cwd, sessionId: safeId)

        // The end-time parent walk can resolve a different PID than at start (ancestors
        // exit during teardown), so the PID-derived path may miss the session's file or
        // hold a different conversation. Key the stamp to session_id (issue #155 P3).
        guard let path = sessionEndTargetPath(primaryPath: primaryPath, sessionsDir: sessionsDir, safeId: safeId) else {
            // No file holds this session. Keep the legacy corrupt-file cleanup on the
            // primary path, but never touch another conversation's healthy file.
            try? withSessionLock(sessionPath: primaryPath, onError: deps.logger.logError) {
                guard (try? Session.fromFile(path: primaryPath)) == nil else { return }
                deps.logger.appendHookLog(sessionId: safeId, event: hookName, label: label, transition: "-> removed")
                removeSession(at: primaryPath, sessionId: safeId, logger: deps.logger)
            }
            return
        }

        // Stamp endedAt instead of deleting — the menubar app archives to history on next poll.
        try? withSessionLock(sessionPath: path, onError: deps.logger.logError) {
            // Re-validate under the lock: the file can change between the scan and the stamp.
            guard var session = try? Session.fromFile(path: path), session.sessionId == safeId else { return }
            let endedAt = Date()
            session.endedAt = endedAt
            if hasTrustedDesktopBundle(session, sourceOverride: input.resolvedHarnessName) {
                session.disconnectedAt = session.disconnectedAt ?? endedAt
            }
            session.markWrittenByHook(version: Config.hookVersion, isNewSessionFile: false)
            try? session.writeToFile(path: path)
            deps.logger.appendHookLog(sessionId: safeId, event: hookName, label: label, transition: "-> ended")
        }
    }

    /// Path of the session file owning `safeId`: the PID-derived path when it matches;
    /// otherwise the best directory match by session_id — preferring a file not yet
    /// ended (the live conversation), then the most recently active one.
    private static func sessionEndTargetPath(primaryPath: String, sessionsDir: String, safeId: String) -> String? {
        if let session = try? Session.fromFile(path: primaryPath), session.sessionId == safeId {
            return primaryPath
        }
        var best: (path: String, session: Session)?
        forEachSession(in: sessionsDir) { path, session in
            guard session.sessionId == safeId else { return }
            guard let current = best else { best = (path, session); return }
            let candidateUnended = session.endedAt == nil
            let currentUnended = current.session.endedAt == nil
            if candidateUnended != currentUnended {
                if candidateUnended { best = (path, session) }
            } else if session.lastActivity > current.session.lastActivity {
                best = (path, session)
            }
        }
        return best?.path
    }

    static func cleanupSessionsForProject(
        sessionsDir: String, projectPath: String, currentPid: UInt32?,
        process: any ProcessProbing = LiveProcessProber(), logger: HookLogger = HookLogger()
    ) {
        forEachSession(in: sessionsDir) { path, session in
            guard session.projectPath == projectPath, session.pid != currentPid else { return }

            // Desktop-app conversations survive host-app restarts as dormant cards in the menubar
            // app and are reaped only by its lock-held GC. The hook must NOT delete them here, or
            // resuming one conversation would reap its dormant same-project siblings.
            guard !hasTrustedDesktopBundle(session) else { return }

            guard !session.hidden, !session.shouldAutoHide else { return }

            let isStale: Bool
            if let pid = session.pid {
                if !process.isAlive(pid: pid) {
                    isStale = true
                } else if let storedStart = session.pidStartTime,
                          let currentStart = process.startTime(pid: pid),
                          abs(storedStart - currentStart) > 1.0 {
                    isStale = true  // PID reused by a different process
                } else if let comm = process.commandName(pid: pid),
                          Session.isForeignHarnessComm(comm, source: session.source) {
                    isStale = true  // PID adopted from/reused by another harness (issue #155)
                } else {
                    isStale = false
                }
            } else {
                // MIGRATION(v0.6.0): Remove no-PID branch after all users have migrated.
                isStale = -session.lastActivity.timeIntervalSinceNow > noPIDMaxAge
            }

            if isStale {
                removeSession(at: path, sessionId: session.sessionId, logger: logger)
            }
        }
    }

    private static func hasTrustedDesktopBundle(_ session: Session, sourceOverride: String? = nil) -> Bool {
        Session.trustsDesktopBundle(
            source: session.source ?? sourceOverride,
            bundleId: session.terminal?.bundleId
        )
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

    private static func removeSession(at path: String, sessionId: String, logger: HookLogger) {
        try? FileManager.default.removeItem(atPath: path)
        // Never remove the .lock here: unlinking a held lock splits the flock inode.
        // The per-session log is keyed by session_id, which another live file can share
        // (one conversation dual-written as <pid>.json and codex-<sid>.json) — only
        // remove the log when no surviving session file still owns it.
        var sharedByOtherFile = false
        forEachSession(in: (path as NSString).deletingLastPathComponent) { otherPath, session in
            if otherPath != path, session.sessionId == sessionId { sharedByOtherFile = true }
        }
        if !sharedByOtherFile {
            logger.cleanupSessionLog(sessionId: sessionId)
        }
    }

    static func isPIDAlive(_ pid: UInt32) -> Bool {
        kill(Int32(pid), 0) == 0 || errno == EPERM
    }
}

// MARK: - Session File Naming

/// The single writer-side source of truth for session file naming. Files are keyed by
/// PID, except Codex where one host process can emit hooks for multiple conversations.
/// The `codex-` prefix also keeps Codex files out of the reader-side legacy UUID-file
/// sweep (`SessionManager.isLegacyUUIDFilename`) — keep both sides in sync.
func sessionFileName(input: HookInput, pid: UInt32, safeSessionId: String) -> String {
    if input.resolvedHarnessName == Session.codexSource {
        return "codex-\(safeSessionId).json"
    }
    return "\(pid).json"
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

// MARK: - Tool Detail Extraction
func extractToolDetail(toolName: String, toolInput: [String: String]?) -> String? {
    guard let toolInput else { return nil }

    let field: String
    switch toolName.lowercased() {
    case "bash": field = "command"
    case "edit", "write", "read": field = "file_path"
    case "grep", "glob": field = "pattern"
    case "webfetch": field = "url"
    case "websearch": field = "query"
    case "task", "agent": field = "description"
    default: return nil
    }

    guard let value = toolInput[field], !value.isEmpty else { return nil }

    if value.count > maxToolDetailLen {
        return String(value.prefix(maxToolDetailLen - 3)) + "..."
    }
    return value
}
