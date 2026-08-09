// swiftlint:disable file_length
import Foundation

private let maxToolDetailLen = 120

enum HookHandler {
    // MIGRATION(v0.6.0): Remove after all users have migrated to PID-keyed sessions.
    private static let noPIDMaxAge: TimeInterval = 300

    // Identity resolution and the lock-held transition stay together so callers cannot
    // accidentally reorder the mapping and session-file locks.
    // swiftlint:disable:next function_body_length
    static func handleHook(hookName: String, input: HookInput, deps: HookDependencies = .live) throws {
        let event = HookEvent.parse(hookName: hookName, notificationType: input.notificationType)

        if event == .sessionEnd {
            handleSessionEnd(hookName: hookName, input: input, deps: deps)
            return
        }

        let sessionsDir = deps.sessionsDir()
        let safeId = SessionData.sanitizeSessionId(raw: input.sessionId)
        let pid = deps.process.parentPID()
        let source = input.resolvedHarnessName ?? SessionData.ccSource
        let label = HookLogger.sessionLabel(cwd: input.cwd, sessionId: safeId)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent(sessionFileName(input: input, pid: pid, safeSessionId: safeId))

        if event == .sessionStart, input.hasCodexStartupDeferralEvidence,
           !FileManager.default.fileExists(atPath: sessionPath) {
            runProjectCleanupIfNeeded(event: event, sessionsDir: sessionsDir, input: input, pid: pid, deps: deps)
            return
        }

        let branch = deps.currentBranch(input.cwd)
        let terminal = captureTerminalInfo(env: deps.environment(), process: deps.process)
        let startTime = deps.process.startTime(pid: pid)
        let cctopSessionId = try resolvedCctopSessionID(
            input: input, sessionPath: sessionPath,
            sessionsDir: sessionsDir, source: source, safeId: safeId
        )

        logForeignHarnessWarning(pid: pid, input: input, hookName: hookName, label: label, deps: deps)

        // Lock the session file for the entire read-modify-write cycle.
        // Without this, concurrent hook processes (e.g. SubagentStart + PreToolUse
        // firing simultaneously) race: both read the old file, apply changes
        // independently, and the last writer wins — clobbering the first writer's changes.
        var didApplyHook = false
        try withSessionLock(sessionPath: sessionPath, onError: deps.logger.logError) {
            var freshData = SessionData(sessionId: safeId, projectPath: input.cwd, branch: branch, terminal: terminal)
            freshData.source = source
            freshData.cctopSessionId = cctopSessionId
            freshData.harnessSessionId = input.sessionId
            let loaded: (data: SessionData, isNewSessionFile: Bool)
            do {
                loaded = try loadOrCreateSession(
                    path: sessionPath, event: event, startTime: startTime, fresh: freshData
                )
            } catch {
                logSessionLoadFailureOnce(hookName: hookName, sessionPath: sessionPath, error: error, logger: deps.logger)
                return
            }
            var data = loaded.data
            let isNewSessionFile = loaded.isNewSessionFile

            data.pid = pid
            data.pidStartTime = startTime
            stampSessionIdentity(
                &data, cctopSessionId: cctopSessionId,
                input: input, source: source, safeId: safeId
            )

            let (oldStatus, newStatus) = applyTransition(&data, event: event, input: input, branch: branch, terminal: terminal)
            applySessionName(&data, event: event, input: input, names: deps.names)
            if event != .sessionStart, isNewSessionFile, source == SessionData.codexSource {
                data.workspaceFile = SessionData.findWorkspaceFile(in: input.cwd)
            }
            applySideEffects(event: event, data: &data, input: input, sessionsDir: sessionsDir, safeId: safeId)
            if input.isSubagentSession == true { data.isSubagentSession = true }
            if data.shouldAutoHide || (event == .userPromptSubmit && input.hasCodexProjectSuggestionEvidence) { data.hidden = true }
            data.markWrittenByHook(version: Config.hookVersion, isNewSessionFile: isNewSessionFile)

            let suffix = newStatus == nil ? " (preserved)" : ""
            deps.logger.appendHookLog(
                sessionId: safeId, event: hookName, label: label,
                transition: "\(oldStatus) -> \(data.status.rawValue)\(suffix)"
            )
            try data.writeToFile(path: sessionPath)
            didApplyHook = true
        }

        if didApplyHook {
            runProjectCleanupIfNeeded(event: event, sessionsDir: sessionsDir, input: input, pid: pid, deps: deps)
        }
    }

    private static func clearToolState(_ data: inout SessionData) {
        clearRunningToolState(&data)
        data.notificationMessage = nil
    }

    private static func clearRunningToolState(_ data: inout SessionData) {
        data.lastTool = nil
        data.lastToolDetail = nil
    }

    private static func applySubagentEvent(event: HookEvent, data: inout SessionData, input: HookInput) {
        switch event {
        case .subagentStart:
            guard let agentId = input.agentId, let agentType = input.agentType else { return }
            if data.activeSubagents == nil { data.activeSubagents = [] }
            if !data.activeSubagents!.contains(where: { $0.agentId == agentId }) {
                data.activeSubagents!.append(
                    SubagentInfo(agentId: agentId, agentType: agentType, startedAt: Date())
                )
            }
        case .subagentStop:
            if let agentId = input.agentId {
                data.activeSubagents?.removeAll { $0.agentId == agentId }
            }
        default:
            break
        }
    }

    /// Apply status transition and update session metadata. Returns (oldStatus, newStatus).
    private static func applyTransition(
        _ data: inout SessionData, event: HookEvent, input: HookInput,
        branch: String, terminal: TerminalInfo
    ) -> (String, SessionStatus?) {
        let oldStatus = data.status.rawValue
        let newStatus = Transition.forEvent(data.status, event: event)
        if let newStatus { data.status = newStatus }
        // Skip lastActivity for notificationPermission — PermissionRequest already set it,
        // and the menubar app needs the original timestamp for child-process-start-time comparison.
        if event != .notificationPermission { data.lastActivity = Date() }
        if Transition.clearsInactiveMarkers(event: event) {
            data.endedAt = nil
            data.disconnectedAt = nil
        }
        data.branch = branch; data.terminal = terminal
        // MIGRATION(harness_name): The session JSON file still uses the `source` key.
        // Renaming the JSON key would require a reader-side migration in SessionManager.
        // Do that in a future PR once `harness_name` is settled.
        if let harness = input.resolvedHarnessName { data.source = harness }
        return (oldStatus, newStatus)
    }

    /// Update the user-visible session name. Runs right after applyTransition, once
    /// source/terminal are current, since the lookup strategy depends on both.
    private static func applySessionName(
        _ data: inout SessionData, event: HookEvent, input: HookInput, names: any SessionNameResolving
    ) {
        if let name = input.sessionName {
            data.sessionName = name
        } else if event == .sessionStart || event == .userPromptSubmit || event == .stop
                    || (data.source == "codex" && data.sessionName == nil) {
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
            if data.source == "codex" {
                lookedUp = names.codexThreadName(sessionId: input.sessionId)
            } else if data.terminal?.bundleId == HostAppBundleID.claudeDesktop {
                lookedUp = names.claudeDesktopTitle(cliSessionId: input.sessionId)
            } else {
                lookedUp = names.transcriptSessionName(
                    transcriptPath: input.transcriptPath, sessionId: input.sessionId
                )
            }
            if let name = lookedUp {
                data.sessionName = name
            }
        }
    }

    private static func applySideEffects(
        event: HookEvent, data: inout SessionData, input: HookInput,
        sessionsDir: String, safeId: String
    ) {
        switch event {
        case .sessionStart:
            clearToolState(&data)
            data.activeSubagents = []
            data.workspaceFile = SessionData.findWorkspaceFile(in: input.cwd)
        case .userPromptSubmit:
            clearToolState(&data)
            if let prompt = input.prompt { data.lastPrompt = prompt }
        case .preToolUse:
            if let toolName = input.toolName {
                data.lastTool = toolName
                data.lastToolDetail = extractToolDetail(toolName: toolName, toolInput: input.toolInput)
            }

        case .permissionRequest:
            let msg = input.title ?? input.toolName.map { tool in
                let detail = extractToolDetail(toolName: tool, toolInput: input.toolInput)
                if let detail { return "\(tool): \(detail)" }
                return tool
            }
            data.notificationMessage = msg
            // Keep lastTool/lastToolDetail from the preceding PreToolUse — when the
            // delayed Notification transitions to .working, the card can show what tool is running.

        case .notificationIdle, .notificationOther:
            applyNotificationEvent(event: event, data: &data, input: input)
        case .stop:
            clearToolState(&data)
        case .postToolUseFailure:
            if let error = input.error { data.notificationMessage = error }
        case .subagentStart, .subagentStop:
            applySubagentEvent(event: event, data: &data, input: input)

        case .sessionError:
            data.notificationMessage = input.error ?? input.message

        // notificationPermission: PermissionRequest already handles side effects; Notification fires ~6s later.
        case .notificationPermission, .postCompact, .preCompact, .postToolUse, .sessionEnd, .unknown:
            break
        }
    }

    private static func applyNotificationEvent(event: HookEvent, data: inout SessionData, input: HookInput) {
        clearRunningToolState(&data)
        if event == .notificationIdle && input.notificationType == "idle_prompt" {
            data.notificationMessage = nil
        } else if let message = input.message {
            data.notificationMessage = message
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
        guard let info = procInfo(pid) else { return nil }
        let tdev = info.kp_eproc.e_tdev
        guard tdev != UInt32.max, let name = devname(tdev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

}

extension HookHandler {
    // MARK: - Cleanup

    // Target selection, identity resolution, and lock-held revalidation form one fail-closed cycle.
    // swiftlint:disable:next function_body_length
    private static func handleSessionEnd(hookName: String, input: HookInput, deps: HookDependencies) {
        let pid = deps.process.parentPID()
        let safeId = SessionData.sanitizeSessionId(raw: input.sessionId)
        let sessionsDir = deps.sessionsDir()
        let primaryPath = (sessionsDir as NSString).appendingPathComponent(sessionFileName(input: input, pid: pid, safeSessionId: safeId))
        let label = HookLogger.sessionLabel(cwd: input.cwd, sessionId: safeId)
        let source = input.resolvedHarnessName ?? SessionData.ccSource

        // The end-time parent walk can resolve a different PID than at start (ancestors
        // exit during teardown), so the PID-derived path may miss the session's file or
        // hold a different conversation. Key the stamp to session_id (issue #155 P3).
        guard let target = sessionEndTarget(
            primaryPath: primaryPath, sessionsDir: sessionsDir, safeId: safeId,
            rawId: input.sessionId, source: source
        ) else {
            // No file holds this session. Keep the legacy corrupt-file cleanup on the
            // primary path, but never touch another conversation's healthy file.
            try? withSessionLock(sessionPath: primaryPath, onError: deps.logger.logError) {
                guard (try? SessionData.fromFile(path: primaryPath)) == nil else { return }
                deps.logger.appendHookLog(sessionId: safeId, event: hookName, label: label, transition: "-> removed")
                removeSession(at: primaryPath, sessionId: safeId, logger: deps.logger)
            }
            return
        }

        let existingTarget = try? SessionData.fromFile(path: target.path)
        let existingCctopSessionId = existingTarget.flatMap { data -> String? in
            guard sessionEndIdentityMatch(
                data, safeId: safeId, rawId: input.sessionId, source: source
            ) == target.match, CctopSessionID.isValid(data.cctopSessionId) else { return nil }
            return data.cctopSessionId
        }
        guard let cctopSessionId = existingCctopSessionId ?? resolvedCctopSessionIDForEnd(
            input: input, sessionsDir: sessionsDir, source: source,
            safeId: safeId, logger: deps.logger
        ) else { return }

        // Stamp endedAt instead of deleting — the menubar app archives to history on next poll.
        try? withSessionLock(sessionPath: target.path, onError: deps.logger.logError) {
            // Re-validate under the lock: the file can change between the scan and the stamp.
            guard var data = try? SessionData.fromFile(path: target.path),
                  sessionEndIdentityMatch(
                    data, safeId: safeId, rawId: input.sessionId, source: source
                  ) == target.match else { return }
            // A legacy match is allowed only while it remains the sole fallback. If an
            // exact record appeared or another legacy candidate became visible after the
            // first scan, fail closed instead of ending an arbitrary record.
            if target.match == .legacy {
                guard sessionEndTarget(
                    primaryPath: primaryPath, sessionsDir: sessionsDir, safeId: safeId,
                    rawId: input.sessionId, source: source
                ) == target else { return }
            }
            let endedAt = Date()
            if shouldAdoptResolvedCctopSessionID(data, input: input, source: source, safeId: safeId) {
                data.cctopSessionId = cctopSessionId
            }
            data.endedAt = endedAt
            if hasTrustedClaudeDesktopBundle(data, sourceOverride: input.resolvedHarnessName) {
                data.disconnectedAt = data.disconnectedAt ?? endedAt
            }
            data.markWrittenByHook(version: Config.hookVersion, isNewSessionFile: false)
            do {
                try data.writeToFile(path: target.path)
            } catch {
                deps.logger.logError("\(hookName): \(error)")
                return
            }
            deps.logger.appendHookLog(sessionId: safeId, event: hookName, label: label, transition: "-> ended")
        }
    }

    private enum SessionEndIdentityMatch: Equatable {
        case exact
        case legacy
    }

    private static func resolveCctopSessionID(
        input: HookInput, sessionsDir: String, source: String, safeId: String
    ) throws -> String {
        try CctopSessionIdentityStore(sessionsDir: URL(fileURLWithPath: sessionsDir)).resolve(
            source: source,
            harnessSessionId: input.sessionId,
            legacySessionId: safeId
        )
    }

    private static func resolvedCctopSessionID(
        input: HookInput, sessionPath: String, sessionsDir: String,
        source: String, safeId: String
    ) throws -> String {
        if let data = try? SessionData.fromFile(path: sessionPath),
           (data.source ?? SessionData.ccSource) == source,
           data.harnessSessionId == input.sessionId,
           CctopSessionID.isValid(data.cctopSessionId),
           let cctopSessionId = data.cctopSessionId {
            return cctopSessionId
        }
        return try resolveCctopSessionID(
            input: input, sessionsDir: sessionsDir, source: source, safeId: safeId
        )
    }

    private static func resolvedCctopSessionIDForEnd(
        input: HookInput, sessionsDir: String,
        source: String, safeId: String, logger: HookLogger
    ) -> String? {
        do {
            return try resolveCctopSessionID(
                input: input, sessionsDir: sessionsDir, source: source, safeId: safeId
            )
        } catch {
            logger.logError("SessionEnd: could not resolve cctop session identity: \(error)")
            return nil
        }
    }

    private static func stampSessionIdentity(
        _ data: inout SessionData, cctopSessionId: String,
        input: HookInput, source: String, safeId: String
    ) {
        if shouldAdoptResolvedCctopSessionID(data, input: input, source: source, safeId: safeId) {
            data.cctopSessionId = cctopSessionId
        }
        // Stamped after a matching event loads the record so pre-field files gain the
        // exact reference mid-life; only SessionStart may rotate conversations.
        data.harnessSessionId = input.sessionId
    }

    private static func shouldAdoptResolvedCctopSessionID(
        _ data: SessionData, input: HookInput, source: String, safeId: String
    ) -> Bool {
        !CctopSessionID.isValid(data.cctopSessionId)
            || CctopSessionIdentityStore.durableEvidence(
                source: source,
                harnessSessionId: input.sessionId,
                legacySessionId: safeId
            ) != nil
    }

    private struct SessionEndTarget: Equatable {
        let path: String
        let match: SessionEndIdentityMatch
    }

    private static func sessionEndIdentityMatch(
        _ data: SessionData, safeId: String, rawId: String, source: String
    ) -> SessionEndIdentityMatch? {
        guard data.sessionId == safeId,
              (data.source ?? SessionData.ccSource) == source else { return nil }
        guard let harnessSessionId = data.harnessSessionId else { return .legacy }
        return harnessSessionId == rawId ? .exact : nil
    }

    /// Find the record owning an ending conversation. Exact raw/source matches win
    /// globally; only when none exist may one unambiguous legacy record fall back to the
    /// lossy sanitized id. The primary PID path breaks ties only between exact matches.
    private static func sessionEndTarget(
        primaryPath: String, sessionsDir: String, safeId: String, rawId: String, source: String
    ) -> SessionEndTarget? {
        var exact: [(path: String, data: SessionData)] = []
        var legacyPaths: [String] = []
        forEachSession(in: sessionsDir) { path, data in
            switch sessionEndIdentityMatch(data, safeId: safeId, rawId: rawId, source: source) {
            case .exact:
                exact.append((path, data))
            case .legacy:
                legacyPaths.append(path)
            case nil:
                break
            }
        }

        if !exact.isEmpty {
            if exact.contains(where: { $0.path == primaryPath }) {
                return SessionEndTarget(path: primaryPath, match: .exact)
            }
            var best = exact[0]
            for candidate in exact.dropFirst() {
                let candidateUnended = candidate.data.endedAt == nil
                let currentUnended = best.data.endedAt == nil
                if candidateUnended != currentUnended {
                    if candidateUnended { best = candidate }
                } else if candidate.data.lastActivity > best.data.lastActivity {
                    best = candidate
                }
            }
            return SessionEndTarget(path: best.path, match: .exact)
        }

        guard legacyPaths.count == 1, let path = legacyPaths.first else { return nil }
        return SessionEndTarget(path: path, match: .legacy)
    }

    static func cleanupSessionsForProject(
        sessionsDir: String, projectPath: String, currentPid: UInt32?,
        process: any ProcessProbing = LiveProcessProber(), logger: HookLogger = HookLogger()
    ) {
        forEachSession(in: sessionsDir) { path, data in
            guard data.projectPath == projectPath, data.pid != currentPid else { return }

            // Retained conversations are reaped by the menubar's lock-held lifecycle GC. The hook
            // must not delete a recent Codex thread or Claude Desktop sibling on a new process start.
            guard !data.isCodex, !hasTrustedClaudeDesktopBundle(data) else { return }

            guard !data.hidden, !data.shouldAutoHide else { return }

            let isStale: Bool
            if let pid = data.pid {
                if !process.isAlive(pid: pid) {
                    isStale = true
                } else if let storedStart = data.pidStartTime,
                          let currentStart = process.startTime(pid: pid),
                          abs(storedStart - currentStart) > 1.0 {
                    isStale = true  // PID reused by a different process
                } else if let comm = process.commandName(pid: pid),
                          SessionData.isForeignHarnessComm(comm, source: data.source) {
                    isStale = true  // PID adopted from/reused by another harness (issue #155)
                } else {
                    isStale = false
                }
            } else {
                // MIGRATION(v0.6.0): Remove no-PID branch after all users have migrated.
                isStale = -data.lastActivity.timeIntervalSinceNow > noPIDMaxAge
            }

            if isStale {
                removeSession(at: path, sessionId: data.sessionId, logger: logger)
            }
        }
    }

    fileprivate static func hasTrustedClaudeDesktopBundle(_ data: SessionData, sourceOverride: String? = nil) -> Bool {
        let bundleID = data.terminal?.bundleId
        return bundleID == HostAppBundleID.claudeDesktop
            && SessionData.trustsDesktopBundle(source: data.source ?? sourceOverride, bundleId: bundleID)
    }

    private static func forEachSession(in dir: String, body: (String, SessionData) -> Void) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for entry in entries where entry.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(entry)
            guard let data = try? SessionData.fromFile(path: path) else { continue }
            body(path, data)
        }
    }

    private static func removeSession(at path: String, sessionId: String, logger: HookLogger) {
        try? FileManager.default.removeItem(atPath: path)
        // Never remove the .lock here: unlinking a held lock splits the flock inode.
        // The per-session log is keyed by session_id, which another live file can share
        // (one conversation dual-written as <pid>.json and codex-<sid>.json) — only
        // remove the log when no surviving session file still owns it.
        var sharedByOtherFile = false
        forEachSession(in: (path as NSString).deletingLastPathComponent) { otherPath, data in
            if otherPath != path, data.sessionId == sessionId { sharedByOtherFile = true }
        }
        if !sharedByOtherFile {
            logger.cleanupSessionLog(sessionId: sessionId)
        }
    }

    static func isPIDAlive(_ pid: UInt32) -> Bool {
        kill(Int32(pid), 0) == 0 || errno == EPERM
    }
}

private func logForeignHarnessWarning(
    pid: UInt32,
    input: HookInput,
    hookName: String,
    label: String,
    deps: HookDependencies
) {
    // Capture-side diagnostic (issue #155 P5): the parent walk should land on this
    // harness's own process. A foreign-harness PID means liveness for this file will
    // track the wrong process — log it so the adoption path can be confirmed in the field.
    guard let parentComm = deps.process.commandName(pid: pid),
          SessionData.isForeignHarnessComm(parentComm, source: input.resolvedHarnessName) else {
        return
    }
    deps.logger.appendHookLog(
        sessionId: SessionData.sanitizeSessionId(raw: input.sessionId), event: hookName, label: label,
        transition: "warning: parent pid \(pid) is '\(parentComm)', a foreign harness"
    )
}

private func runProjectCleanupIfNeeded(
    event: HookEvent,
    sessionsDir: String,
    input: HookInput,
    pid: UInt32,
    deps: HookDependencies
) {
    // Cleanup runs outside the lock: it scans all session files and makes sysctl calls per file.
    guard event == .sessionStart else { return }
    HookHandler.cleanupSessionsForProject(
        sessionsDir: sessionsDir, projectPath: input.cwd, currentPid: pid,
        process: deps.process, logger: deps.logger
    )
}

private func loadOrCreateSession(
    path: String, event: HookEvent, startTime: TimeInterval?, fresh: SessionData
) throws -> (data: SessionData, isNewSessionFile: Bool) {
    guard FileManager.default.fileExists(atPath: path) else {
        return (fresh, true)
    }
    let existing: SessionData
    do {
        existing = try decodeExistingSessionFile(path: path)
    } catch SessionLoadError.undecodableExistingFile(_) where event == .sessionStart {
        return (fresh, true)
    }
    let sameConversation = existing.sessionId == fresh.sessionId
        && (existing.harnessSessionId == nil || existing.harnessSessionId == fresh.harnessSessionId)
    // PID reuse: different process start time means a new process reused this PID.
    if event == .sessionStart,
       let storedStart = existing.pidStartTime,
       let currentStart = startTime,
       abs(storedStart - currentStart) > 1.0 {
        if existing.isCodex, fresh.isCodex, sameConversation {
            return (existing, false)
        }
        guard canReplaceDecodedSessionFile(existing: existing, fresh: fresh, event: event) else {
            throw SessionLoadError.decodedReplacementRefused(
                existingSessionId: existing.sessionId,
                incomingSessionId: fresh.sessionId
            )
        }
        var replacement = fresh
        if CctopSessionIdentityStore.durableEvidence(for: fresh) == nil {
            replacement.cctopSessionId = CctopSessionID.make()
        }
        return (replacement, true)
    }
    // Same PID, different session — a PID-keyed source reused the process for a new
    // conversation. Raw references are compared when the record has one, so two
    // conversations whose sanitized ids collide don't silently share a record; legacy
    // records without the field can only compare sanitized ids. Drop conversation-specific
    // state (project, name, prompt, tools, etc.) and carry over only PID liveness metadata.
    guard sameConversation else {
        guard canReplaceDecodedSessionFile(existing: existing, fresh: fresh, event: event) else {
            throw SessionLoadError.decodedReplacementRefused(
                existingSessionId: existing.sessionId,
                incomingSessionId: fresh.sessionId
            )
        }
        var carried = fresh
        carried.pid = existing.pid
        carried.pidStartTime = existing.pidStartTime
        return (carried, true)
    }
    return (existing, false)
}

private enum SessionLoadError: Error, CustomStringConvertible {
    case unreadableExistingFile(Error)
    case undecodableExistingFile(Error)
    case decodedReplacementRefused(existingSessionId: String, incomingSessionId: String)

    var description: String {
        switch self {
        case let .unreadableExistingFile(error):
            "existing session file could not be read: \(error)"
        case let .undecodableExistingFile(error):
            "existing session file could not be decoded: \(error)"
        case let .decodedReplacementRefused(existingSessionId, incomingSessionId):
            "decoded session mismatch refused (existing session_id \(existingSessionId), incoming \(incomingSessionId))"
        }
    }
}

private func decodeExistingSessionFile(path: String) throws -> SessionData {
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        throw SessionLoadError.unreadableExistingFile(error)
    }

    do {
        return try JSONDecoder.sessionDecoder.decode(SessionData.self, from: data)
    } catch {
        throw SessionLoadError.undecodableExistingFile(error)
    }
}

private func logSessionLoadFailureOnce(hookName: String, sessionPath: String, error: Error, logger: HookLogger) {
    let marker = "load-failure:\(hookName):\(sessionPath)"
    let errorsPath = (logger.logsDir as NSString).appendingPathComponent("_errors.log")
    if let existing = try? String(contentsOfFile: errorsPath, encoding: .utf8),
       existing.contains(marker) {
        return
    }
    logger.logError(
        "\(hookName): preserving existing session file at \(sessionPath) after load failure: \(error) [\(marker)]"
    )
}

private func canReplaceDecodedSessionFile(existing: SessionData, fresh: SessionData, event: HookEvent) -> Bool {
    guard event == .sessionStart else { return false }
    guard existing.source != SessionData.codexSource, fresh.source != SessionData.codexSource else { return false }
    guard !HookHandler.hasTrustedClaudeDesktopBundle(existing),
          !HookHandler.hasTrustedClaudeDesktopBundle(fresh) else {
        return false
    }
    return true
}

// MARK: - Session File Naming

/// The single writer-side source of truth for session file naming. Files are keyed by
/// PID, except Codex where one host process can emit hooks for multiple conversations.
/// The `codex-` prefix also keeps Codex files out of the reader-side legacy UUID-file
/// sweep (`SessionManager.isLegacyUUIDFilename`) — keep both sides in sync.
func sessionFileName(input: HookInput, pid: UInt32, safeSessionId: String) -> String {
    if input.resolvedHarnessName == SessionData.codexSource {
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
    case "bash", "local_shell": field = "command"
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
