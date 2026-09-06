import Foundation

// MARK: - Session end and stale-session cleanup

extension HookHandler {
    // Target selection, identity resolution, and lock-held revalidation form one fail-closed cycle.
    // swiftlint:disable:next function_body_length
    static func handleSessionEnd(hookName: String, input: HookInput, deps: HookDependencies) {
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

    static func resolvedCctopSessionID(
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

    static func stampSessionIdentity(
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
            // A record without a PID cannot be liveness-checked here; the app's legacy-file sweep owns it.
            guard let pid = data.pid else { return }

            let isStale: Bool
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

            if isStale {
                removeSession(at: path, sessionId: data.sessionId, logger: logger)
            }
        }
    }

    static func hasTrustedClaudeDesktopBundle(_ data: SessionData, sourceOverride: String? = nil) -> Bool {
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
}
