import Darwin
import Foundation

struct SessionLoadSummary: Equatable {
    let files: Int
    let decoded: Int
    let live: Int
    let hidden: Int
    let autoHidden: Int
}

struct SessionLoadLogSignature: Equatable {
    let summary: SessionLoadSummary
    let archivedCodexThreadIDs: Int
    let missingCodexDesktopThreadIDs: Int
    let codexSubagentThreadIDs: Int
    let codexExecHelperThreadIDs: Int
    let archivedClaudeSessionIDs: Int
}

struct SessionFileCacheEntry {
    let fingerprint: SessionFileFingerprint
    let session: Session
}

struct SessionFileFingerprint: Equatable {
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let fileSize: Int64
}

extension SessionManager {
    func decodedSessions(from jsonFiles: [URL]) -> [(url: URL, session: Session)] {
        let currentPaths = Set(jsonFiles.map(\.path))
        sessionFileCache = sessionFileCache.filter { currentPaths.contains($0.key) }

        return jsonFiles.compactMap { url in
            guard let fingerprint = sessionFileFingerprint(for: url) else {
                sessionFileCache.removeValue(forKey: url.path)
                sessionManagerLogger.warning("loadSessions: could not stat \(url.lastPathComponent, privacy: .public)")
                return nil
            }
            if let cached = sessionFileCache[url.path], cached.fingerprint == fingerprint {
                return (url, cached.session)
            }
            guard let data = try? Data(contentsOf: url) else {
                sessionFileCache.removeValue(forKey: url.path)
                sessionManagerLogger.warning("loadSessions: could not read \(url.lastPathComponent, privacy: .public)")
                return nil
            }
            do {
                let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: data)
                sessionFileCache[url.path] = SessionFileCacheEntry(
                    fingerprint: fingerprint,
                    session: session
                )
                return (url, session)
            } catch {
                sessionFileCache.removeValue(forKey: url.path)
                sessionManagerLogger.error("loadSessions: decode failed \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                return nil
            }
        }
    }

    private func sessionFileFingerprint(for url: URL) -> SessionFileFingerprint? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return SessionFileFingerprint(
            modifiedSeconds: Int(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec),
            fileSize: Int64(info.st_size)
        )
    }

    /// Derives lifecycle-stamped candidates and the visibility classification for one load pass,
    /// reading desktop archive state and process liveness through the injected data sources.
    func deriveVisibility(from visibleDecoded: [(url: URL, session: Session)]) -> SessionVisibilitySnapshot {
        let now = dataSources.now()
        let claudeMetadata = Self.claudeDesktopMetadataSnapshot(
            in: visibleDecoded.map(\.session),
            claudeDesktopSessions: dataSources.claudeDesktopSessions
        )
        let candidates = Self.buildCandidates(
            visibleDecoded,
            now: now,
            desktopAppConnectionLookup: dataSources.desktopAppConnection,
            claudeMetadata: claudeMetadata,
            codexThreads: dataSources.codexThreads,
            processAlive: dataSources.processAlive
        )
        return Self.visibilitySnapshot(
            in: candidates,
            claudeMetadata: claudeMetadata,
            codexThreads: dataSources.codexThreads,
            now: now
        )
    }

    func currentStatusesByStableKey() -> [String: SessionStatus] {
        Dictionary(
            sessions.map { (SessionIdentityPolicy.stableKey(for: $0), $0.status) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func sessionJSONFiles(in files: [URL]) -> [URL] {
        files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".tmp") }
    }

    func logLoadSummary(_ summary: SessionLoadSummary, visibility: SessionVisibilitySnapshot) {
        let signature = SessionLoadLogSignature(
            summary: summary,
            archivedCodexThreadIDs: visibility.archivedCodexThreadIDs.count,
            missingCodexDesktopThreadIDs: visibility.missingCodexDesktopThreadIDs.count,
            codexSubagentThreadIDs: visibility.codexSubagentThreadIDs.count,
            codexExecHelperThreadIDs: visibility.codexExecHelperThreadIDs.count,
            archivedClaudeSessionIDs: visibility.archivedClaudeSessionIDs.count
        )
        guard signature != lastLoadLogSignature else { return }
        lastLoadLogSignature = signature

        sessionManagerLogger.info("loadSessions: \(summary.files) files, \(summary.decoded) decoded")
        sessionManagerLogger.info(
            "loadSessions: \(summary.live) visible candidates, \(summary.hidden) hidden, \(summary.autoHidden) auto-hidden"
        )
        sessionManagerLogger.info("loadSessions: \(visibility.archivedCodexThreadIDs.count) codex-archived")
        sessionManagerLogger.info("loadSessions: \(visibility.missingCodexDesktopThreadIDs.count) codex-missing-state")
        sessionManagerLogger.info("loadSessions: \(visibility.codexSubagentThreadIDs.count) codex-subagent")
        sessionManagerLogger.info("loadSessions: \(visibility.codexExecHelperThreadIDs.count) codex-exec-helper")
        sessionManagerLogger.info("loadSessions: \(visibility.archivedClaudeSessionIDs.count) claude-archived")
    }
}

#if DEBUG
extension SessionManager {
    func recordDebugNoActiveSessionsState(
        _ newSessions: [Session],
        _ displaySignature: SessionDisplayPolicy.Signature,
        _ summary: SessionLoadSummary,
        _ visibility: SessionVisibilitySnapshot,
        _ now: Date
    ) {
        let activeSessionIDs = SessionDisplayPolicy.activeSessions(from: newSessions, now: now)
            .map(\.sessionId)
        defer { debugLastDisplayedActiveSessionIDs = activeSessionIDs }

        guard let previousActiveIDs = debugLastDisplayedActiveSessionIDs,
              !previousActiveIDs.isEmpty,
              displaySignature.activeIDs.isEmpty,
              !newSessions.isEmpty else {
            return
        }
        DebugUIStateLogger.appendNoActiveSessionsWarning(DebugNoActiveSessionsContext(
            previousActiveSessionIDs: previousActiveIDs,
            newSessions: newSessions,
            displaySignature: displaySignature,
            summary: summary,
            visibility: visibility,
            sessionsDir: dataSources.sessionsDir,
            now: now
        ))
    }
}

private struct DebugNoActiveSessionsContext {
    let previousActiveSessionIDs: [String]
    let newSessions: [Session]
    let displaySignature: SessionDisplayPolicy.Signature
    let summary: SessionLoadSummary
    let visibility: SessionVisibilitySnapshot
    let sessionsDir: URL
    let now: Date
}

private enum DebugUIStateLogger {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func appendNoActiveSessionsWarning(_ context: DebugNoActiveSessionsContext) {
        let logURL = debugLogURL()
        let payload = noActiveSessionsPayload(context, logURL: logURL)
        append(payload, to: logURL)
        sessionManagerLogger.warning(
            "debug: Active display bucket became empty; wrote \(logURL.path, privacy: .public)"
        )
    }

    private static func noActiveSessionsPayload(
        _ context: DebugNoActiveSessionsContext,
        logURL: URL
    ) -> [String: Any] {
        let activeSessions = SessionDisplayPolicy.activeSessions(from: context.newSessions, now: context.now)
        let idleSessions = SessionDisplayPolicy.idleSessions(from: context.newSessions, now: context.now)
        let payload: [String: Any] = [
            "schema_version": 1,
            "timestamp": formatter.string(from: context.now),
            "event": "no_active_sessions_displayed",
            "warning": "Visible sessions remain, but the Active display bucket became empty.",
            "previous_active_ids": context.previousActiveSessionIDs,
            "previous_active_count": context.previousActiveSessionIDs.count,
            "new_active_ids": activeSessions.map(\.sessionId),
            "new_active_display_ids": context.displaySignature.activeIDs,
            "new_active_count": activeSessions.count,
            "idle_ids": idleSessions.map(\.sessionId),
            "idle_display_ids": context.displaySignature.idleIDs,
            "idle_count": idleSessions.count,
            "new_session_count": context.newSessions.count,
            "status_counts": counts(context.newSessions.map { $0.status.rawValue }),
            "lifecycle_counts": counts(context.newSessions.map { lifecycleName($0.lifecycle) }),
            "host_class_counts": counts(context.newSessions.map { hostClassName($0.hostClass) }),
            "paths": [
                "sessions_dir": context.sessionsDir.path,
                "log_path": logURL.path,
                "codex_state_db_candidates": Config.codexStateDatabaseCandidates(),
                "codex_session_index": Config.codexSessionIndexPath(),
                "claude_code_sessions_dir": Config.claudeCodeSessionsDir()
            ],
            "environment": environmentSnapshot(),
            "load_summary": [
                "files": context.summary.files,
                "decoded": context.summary.decoded,
                "live": context.summary.live,
                "hidden": context.summary.hidden,
                "auto_hidden": context.summary.autoHidden
            ],
            "visibility": [
                "archived_codex_thread_ids": Array(context.visibility.archivedCodexThreadIDs).sorted(),
                "missing_codex_desktop_thread_ids": Array(context.visibility.missingCodexDesktopThreadIDs).sorted(),
                "codex_subagent_thread_ids": Array(context.visibility.codexSubagentThreadIDs).sorted(),
                "codex_exec_helper_thread_ids": Array(context.visibility.codexExecHelperThreadIDs).sorted(),
                "archived_claude_session_ids": Array(context.visibility.archivedClaudeSessionIDs).sorted()
            ],
            "sessions": context.newSessions.map(sessionSnapshot)
        ]
        return payload
    }

    private static func append(_ payload: [String: Any], to url: URL) {
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        data.append(0x0a)

        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try? fm.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if fm.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private static func debugLogURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["CCTOP_DEBUG_UI_STATE_LOG"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: Config.standardizedPath(override))
        }
        let logsDir = (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent(".cctop/logs")
        return URL(fileURLWithPath: (logsDir as NSString).appendingPathComponent("ui-state-debug.jsonl"))
    }

    private static func sessionSnapshot(_ session: Session) -> [String: Any] {
        [
            "id": session.id,
            "session_id": session.sessionId,
            "source": optional(session.source),
            "status": session.status.rawValue,
            "lifecycle": lifecycleName(session.lifecycle),
            "host_class": hostClassName(session.hostClass),
            "project_path": session.projectPath,
            "project_name": session.projectName,
            "desktop_project_name": optional(session.desktopProjectName),
            "branch": session.branch,
            "terminal_program": optional(session.terminal?.program),
            "terminal_bundle_id": optional(session.terminal?.bundleId),
            "terminal_session_id": optional(session.terminal?.sessionId),
            "tty": optional(session.terminal?.tty),
            "pid": optional(session.pid),
            "pid_start_time": optional(session.pidStartTime),
            "started_at": date(session.startedAt),
            "last_activity": date(session.lastActivity),
            "ended_at": date(session.endedAt),
            "disconnected_at": date(session.disconnectedAt),
            "hidden": session.hidden,
            "should_auto_hide": session.shouldAutoHide,
            "is_subagent_session": session.isSubagentSession,
            "active_subagent_count": session.subagentCount,
            "last_tool": optional(session.lastTool),
            "last_tool_detail": optional(session.lastToolDetail),
            "notification_message": optional(session.notificationMessage),
            "session_name": optional(session.sessionName),
            "last_prompt_length": session.lastPrompt?.count ?? 0,
            "last_prompt_prefix": optional(session.lastPrompt.map { String($0.prefix(300)) }),
            "created_by_hook_version": optional(session.createdByHookVersion),
            "last_written_by_hook_version": optional(session.lastWrittenByHookVersion),
            "is_codex_desktop_host": session.isCodexDesktopHost,
            "is_claude_desktop_host": session.isClaudeDesktopHost
        ]
    }

    private static func environmentSnapshot() -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        let names = [
            "CCTOP_SESSIONS_DIR",
            "CCTOP_CODEX_STATE_DB",
            "CCTOP_CODEX_SESSION_INDEX",
            "CCTOP_CLAUDE_CODE_SESSIONS_DIR",
            "CCTOP_DEBUG_UI_STATE_LOG",
            "CODEX_HOME"
        ]
        return Dictionary(uniqueKeysWithValues: names.map { ($0, optional(environment[$0])) })
    }

    private static func counts(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { result, value in
            result[value, default: 0] += 1
        }
    }

    private static func lifecycleName(_ lifecycle: SessionLifecycle) -> String {
        switch lifecycle {
        case .active: return "active"
        case .dormant: return "dormant"
        case .finished: return "finished"
        }
    }

    private static func hostClassName(_ hostClass: SessionHostClass) -> String {
        switch hostClass {
        case .desktop: return "desktop"
        case .terminal: return "terminal"
        case .ambiguous: return "ambiguous"
        }
    }

    private static func optional(_ value: String?) -> Any {
        value ?? NSNull()
    }

    private static func optional(_ value: UInt32?) -> Any {
        value.map { Int($0) } ?? NSNull()
    }

    private static func optional(_ value: TimeInterval?) -> Any {
        value ?? NSNull()
    }

    private static func date(_ value: Date?) -> Any {
        guard let value else { return NSNull() }
        return formatter.string(from: value)
    }
}
#endif
