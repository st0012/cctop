import Foundation

private let maxToolDetailLen = 120

enum HookHandler {
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
