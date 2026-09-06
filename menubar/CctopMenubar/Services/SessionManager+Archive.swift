import Foundation

extension SessionManager {
    func retainedFinishedCleanupSources(
        winners: [SessionRecord],
        manualHides: ManualHideEvidence
    ) -> [SessionDataCleanupSource] {
        winners.compactMap { candidate in
            let data = candidate.data
            guard candidate.lifecycleRank == SessionLifecycle.finished.rawValue,
                  shouldRetainFinishedManualHideEvidence(data, matching: manualHides),
                  data.hasCleanupSourcePath else {
                return nil
            }
            return SessionDataCleanupSource(data: data)
        }
    }

    func archiveAndRemoveFinishedNonDesktop(
        _ candidates: [SessionRecord],
        winners: [SessionRecord],
        manualHides: ManualHideEvidence
    ) -> [SessionDataCleanupSource] {
        let winnerPaths = Set(winners.map(\.path))
        var newlyArchivedCleanupSources: [SessionDataCleanupSource] = []
        for candidate in candidates {
            guard !shouldRetainFinishedManualHideEvidence(candidate.data, matching: manualHides) else { continue }
            // A finished dedup winner is a real completed non-desktop session, so keep today's
            // Recent Projects behavior. A finished duplicate loser is stale migration debris;
            // remove it without archiving so it cannot later surface as a separate session.
            if winnerPaths.contains(candidate.path) {
                if let cleanupSource = archiveAndRemove(candidate) {
                    newlyArchivedCleanupSources.append(cleanupSource)
                }
            } else {
                removeStaleDuplicate(candidate)
            }
        }
        return newlyArchivedCleanupSources
    }

    func shouldRetainFinishedManualHideEvidence(
        _ data: SessionData,
        matching manualHides: ManualHideEvidence
    ) -> Bool {
        manualHides.matches(data) || hasExistingMappedManualHide(data)
    }

    func hasExistingMappedManualHide(_ data: SessionData) -> Bool {
        guard !CctopSessionID.isValid(data.cctopSessionId) else { return false }
        let hiddenSessionIDs = dataSources.manualSessionVisibility.hiddenSessionIDs
        guard !hiddenSessionIDs.isEmpty,
              let existingID = try? CctopSessionIdentityStore(sessionsDir: dataSources.sessionsDir).existingIdentity(
                  source: data.source,
                  harnessSessionId: data.harnessSessionId,
                  legacySessionId: data.sessionId
              ) else {
            return false
        }
        return hiddenSessionIDs.contains(existingID)
    }

    func sweepLegacyUUIDFileIfNeeded(
        _ url: URL,
        manualHides: ManualHideEvidence
    ) -> Bool {
        guard Self.isLegacyUUIDFilename(url.deletingPathExtension().lastPathComponent) else { return false }
        if !dataSources.manualSessionVisibility.hasStoredHideEvidence {
            try? FileManager.default.removeItem(at: url) // Pre-PID legacy file; no live writer to race.
        } else if let data = try? SessionData.fromFile(path: url.path),
                  !shouldRetainFinishedManualHideEvidence(data, matching: manualHides) {
            try? FileManager.default.removeItem(at: url)
        }
        return true
    }

    func mergingCleanupSources(
        _ retained: [SessionDataCleanupSource],
        with replacements: [SessionDataCleanupSource]
    ) -> [SessionDataCleanupSource] {
        retained.filter { source in
            !replacements.contains {
                $0.sessionId == source.sessionId && $0.projectPath == source.projectPath
            }
        } + replacements
    }

    private func archiveAndRemove(_ candidate: SessionRecord) -> SessionDataCleanupSource? {
        let data = candidate.data
        // A dead non-desktop process holds no lock, so removing its .json needs no flock. Remove
        // the .json ONLY — never the .lock (unlinking a lock a hook still holds splits the inode).
        if historyManager.archiveSession(data) {
            try? FileManager.default.removeItem(atPath: candidate.path)
            return data.hasCleanupSourcePath ? SessionDataCleanupSource(data: data) : nil
        } else {
            sessionManagerLogger.warning("skipping removal of \(data.sessionId, privacy: .public) — archive failed")
            return nil
        }
    }

    private func removeStaleDuplicate(_ candidate: SessionRecord) {
        sessionManagerLogger.info("removing stale duplicate session file \(candidate.path, privacy: .public)")
        try? FileManager.default.removeItem(atPath: candidate.path)
    }

    nonisolated static func desktopAppRunningByBundleID(
        in sessions: [SessionData],
        lookup: DesktopAppConnectionLookup
    ) -> [String: Bool] {
        let bundleIDs = Set(sessions.compactMap { session -> String? in
            guard session.hostClass == .desktop else { return nil }
            return session.terminal?.bundleId
        })
        return lookup.runningStates(bundleIDs)
    }

    nonisolated static func desktopAppRunning(
        for session: SessionData,
        runningByBundleID: [String: Bool]
    ) -> Bool? {
        guard session.hostClass == .desktop,
              let bundleID = session.terminal?.bundleId else {
            return nil
        }
        return runningByBundleID[bundleID]
    }

    nonisolated static func desktopAppRunning(
        for session: SessionData,
        lookup: DesktopAppConnectionLookup
    ) -> Bool? {
        guard session.hostClass == .desktop,
              let bundleID = session.terminal?.bundleId else {
            return nil
        }
        return lookup.isRunning(bundleID)
    }

    func preloadArchiveStateForFinishedRetainedSessions(
        in jsonFiles: [URL],
        now: Date
    ) {
        var finished: [SessionData] = []
        for url in jsonFiles {
            guard !Self.isLegacyUUIDFilename(url.deletingPathExtension().lastPathComponent),
                  let data = try? SessionData.fromFile(path: url.path),
                  !data.hidden,
                  !data.shouldAutoHide,
                  data.isCodex || data.hostClass == .desktop else {
                continue
            }
            if deriveLifecycle(for: data, now: now) == .finished {
                finished.append(data)
            }
        }

        let codexFinishedIDs = Set(finished.filter(\.isCodex).map(\.sessionId))
        let claudeFinishedIDs = Set(finished.filter(\.isClaudeDesktopHost).map(\.sessionId))
        if !codexFinishedIDs.isEmpty {
            _ = dataSources.codexThreads.archivedThreadIDs(matching: codexFinishedIDs)
        }
        if !claudeFinishedIDs.isEmpty {
            _ = dataSources.claudeDesktopSessions.archivedSessionIDs(matching: claudeFinishedIDs)
        }
    }

    /// Fresh single-session archive check for the GC deletion decision. Unlike the batch snapshot
    /// `loadSessions` uses, this re-reads Codex thread state at call time, including rollout
    /// placement when available, so a thread archived after the GC directory scan is never deleted
    /// out from under a pending unarchive. When the store exists but cannot be read, the lookup
    /// returns nil and we fail SAFE.
    nonisolated static func isCodexThreadArchived(
        _ session: SessionData,
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup()
    ) -> Bool {
        guard session.isCodex else { return false }
        guard let archived = codexThreads.archivedThreadIDs(matching: [session.sessionId]) else {
            return true
        }
        return archived.contains(session.sessionId)
    }

    /// Fresh single-session archive check for Claude Desktop's GC deletion decision. Missing
    /// metadata means "not archived"; unreadable matching metadata means "unknown" and keeps the
    /// file.
    nonisolated static func isClaudeDesktopSessionArchived(
        _ session: SessionData,
        claudeDesktopSessions: any ClaudeDesktopSessionStateProviding = ClaudeDesktopSessionArchiveLookup()
    ) -> Bool {
        guard session.isClaudeDesktopHost else { return false }
        guard let archived = claudeDesktopSessions.archivedSessionIDs(matching: [session.sessionId]) else {
            return true
        }
        return archived.contains(session.sessionId)
    }

    nonisolated static func isArchivedRetainedSession(
        _ session: SessionData,
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup(),
        claudeDesktopSessions: any ClaudeDesktopSessionStateProviding = ClaudeDesktopSessionArchiveLookup()
    ) -> Bool {
        isCodexThreadArchived(session, codexThreads: codexThreads)
            || isClaudeDesktopSessionArchived(session, claudeDesktopSessions: claudeDesktopSessions)
    }

    /// Decode each session file, derive its lifecycle, and capture mtime — the inputs the dedup
    /// comparator needs. Pure (no published state), kept off the main class body.
    nonisolated static func buildCandidates(
        _ sessionFiles: [(url: URL, session: SessionData)],
        now: Date,
        desktopAppConnectionLookup: DesktopAppConnectionLookup = .live,
        claudeMetadata: ClaudeDesktopSessionMetadataSnapshot?,
        processAlive: (SessionData) -> Bool = { $0.isAlive }
    ) -> [SessionRecord] {
        let projectNames = claudeMetadata?.projectNamesBySessionID ?? [:]
        let desktopAppRunningByBundleID = desktopAppRunningByBundleID(
            in: sessionFiles.map(\.session),
            lookup: desktopAppConnectionLookup
        )
        var candidates: [SessionRecord] = []
        for (url, var data) in sessionFiles {
            if let projectName = projectNames[data.sessionId] {
                data.desktopProjectName = projectName
            }
            data.lifecycle = SessionLifecyclePolicy.lifecycle(
                for: data, hostClass: data.hostClass, processAlive: processAlive(data),
                now: now, windows: lifecycleWindows,
                desktopAppRunning: desktopAppRunning(for: data, runningByBundleID: desktopAppRunningByBundleID)
            )
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            candidates.append(SessionRecord(data: data, lifecycleRank: data.lifecycle.rawValue,
                                             mtime: mtime, path: url.path))
        }
        return candidates
    }

    nonisolated static func buildCandidates(
        _ jsonFiles: [URL],
        now: Date,
        desktopAppConnectionLookup: DesktopAppConnectionLookup = .live,
        claudeDesktopSessions: any ClaudeDesktopSessionStateProviding = ClaudeDesktopSessionArchiveLookup(),
        processAlive: (SessionData) -> Bool = { $0.isAlive }
    ) -> [SessionRecord] {
        let sessionFiles: [(url: URL, session: SessionData)] = jsonFiles.compactMap { url in
            guard let fileData = try? Data(contentsOf: url) else {
                sessionManagerLogger.warning("loadSessions: could not read \(url.lastPathComponent, privacy: .public)")
                return nil
            }
            guard let data = try? JSONDecoder.sessionDecoder.decode(SessionData.self, from: fileData) else {
                sessionManagerLogger.error("loadSessions: decode failed \(url.lastPathComponent, privacy: .public)")
                return nil
            }
            return (url, data)
        }

        let claudeMetadata = claudeDesktopMetadataSnapshot(
            in: sessionFiles.map(\.session),
            claudeDesktopSessions: claudeDesktopSessions
        )
        return buildCandidates(
            sessionFiles,
            now: now,
            desktopAppConnectionLookup: desktopAppConnectionLookup,
            claudeMetadata: claudeMetadata,
            processAlive: processAlive
        )
    }

    func withSessionLockForMaintenance(
        sessionPath: String,
        sessionId: String,
        action: String,
        body: () throws -> Void
    ) {
        do {
            let didAcquire = try withSessionLockIfAvailable(
                sessionPath: sessionPath,
                onError: { sessionManagerLogger.warning("\($0, privacy: .public)") },
                body: body
            )
            if !didAcquire {
                sessionManagerLogger.info(
                    "skipping \(action, privacy: .public) for \(sessionId, privacy: .public): session lock is busy"
                )
            }
        } catch {
            sessionManagerLogger.warning(
                "skipping \(action, privacy: .public) for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

}
