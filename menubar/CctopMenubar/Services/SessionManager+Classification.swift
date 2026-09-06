import Foundation

extension SessionManager {
    nonisolated static func sessionClassificationSnapshot(
        in candidates: [SessionRecord],
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup(),
        claudeDesktopSessions: any ClaudeDesktopSessionStateProviding = ClaudeDesktopSessionArchiveLookup(),
        now: Date = Date()
    ) -> SessionClassificationSnapshot {
        let sessions = candidates.map(\.data)
        let claudeMetadata = claudeDesktopMetadataSnapshot(in: sessions, claudeDesktopSessions: claudeDesktopSessions)
        return sessionClassificationSnapshot(
            in: candidates,
            sessions: sessions,
            claudeMetadata: claudeMetadata,
            codexThreads: codexThreads,
            now: now
        )
    }

    nonisolated static func sessionClassificationSnapshot(
        in candidates: [SessionRecord],
        claudeMetadata: ClaudeDesktopSessionMetadataSnapshot?,
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup(),
        now: Date = Date()
    ) -> SessionClassificationSnapshot {
        sessionClassificationSnapshot(
            in: candidates,
            sessions: candidates.map(\.data),
            claudeMetadata: claudeMetadata,
            codexThreads: codexThreads,
            now: now
        )
    }

    private nonisolated static func sessionClassificationSnapshot(
        in candidates: [SessionRecord],
        sessions: [SessionData],
        claudeMetadata: ClaudeDesktopSessionMetadataSnapshot?,
        codexThreads: any CodexThreadStateProviding,
        now: Date
    ) -> SessionClassificationSnapshot {
        let externallyClassifiableSessions = sessions.filter { !$0.hidden && !$0.shouldAutoHide }
        let codexDelegationIndex = codexThreads.stateIndex(
            matching: codexThreadIDs(in: sessions)
        )
        let archivedCodexThreadIDs = codexDelegationIndex?.archivedThreadIDs.intersection(
            codexThreadIDs(in: sessions)
        ) ?? []
        let missingCodexThreadIDs = missingCodexThreadIDs(
            in: externallyClassifiableSessions,
            index: codexDelegationIndex,
            now: now
        )
        let codexInternalHelperThreadIDs = codexDelegationIndex?.internalHelperThreadIDs ?? []
        let uncertainCodexDelegationThreadIDs = codexDelegationIndex?.uncertainDelegationThreadIDs ?? []
        let contradictoryCodexDelegationThreadIDs = codexDelegationIndex?.contradictoryDelegationThreadIDs ?? []
        let codexExecHelperThreadIDs = codexExecHelperThreadIDs(
            in: externallyClassifiableSessions,
            index: codexDelegationIndex
        )
        let archivedClaudeSessionIDs = claudeMetadata?.archivedSessionIDs ?? []

        let evidence = SessionClassificationEvidence(
            archivedCodexThreadIDs: archivedCodexThreadIDs,
            missingCodexThreadIDs: missingCodexThreadIDs,
            codexInternalHelperThreadIDs: codexInternalHelperThreadIDs,
            uncertainCodexDelegationThreadIDs: uncertainCodexDelegationThreadIDs,
            contradictoryCodexDelegationThreadIDs: contradictoryCodexDelegationThreadIDs,
            codexExecHelperThreadIDs: codexExecHelperThreadIDs,
            archivedClaudeSessionIDs: archivedClaudeSessionIDs
        )
        let records = candidates.map { candidate in
            ClassifiedSessionRecord(
                url: URL(fileURLWithPath: candidate.path),
                candidate: candidate,
                disposition: disposition(
                    for: candidate.data,
                    evidence: evidence,
                    claudeMetadata: claudeMetadata
                )
            )
        }
        return SessionClassificationSnapshot(records: records, evidence: evidence)
    }

    private nonisolated static func disposition(
        for data: SessionData,
        evidence: SessionClassificationEvidence,
        claudeMetadata: ClaudeDesktopSessionMetadataSnapshot?
    ) -> SessionDisposition {
        // Priority is behavior-bearing: Codex archive wins so no other hidden reason can protect
        // an archived path from Cleanup. Durable local hides then precede external missing/helper state.
        let isArchivedCodexSession = data.isCodex
            && evidence.archivedCodexThreadIDs.contains(data.sessionId)
        if isArchivedCodexSession {
            return .hidden(.archivedCodexThread)
        }
        if data.hidden {
            return .hidden(.persistedHidden)
        }
        if data.shouldAutoHide {
            return .hidden(.autoHidden)
        }
        if isMissingCodexSession(data, missingThreadIDs: evidence.missingCodexThreadIDs) {
            return .hidden(.missingCodexThread)
        }
        if isCodexInternalHelperSession(data, internalHelperThreadIDs: evidence.codexInternalHelperThreadIDs) {
            return .hidden(.codexInternalHelper)
        }
        if isCodexExecHelperSession(data, execHelperThreadIDs: evidence.codexExecHelperThreadIDs) {
            return .hidden(.codexExecHelper)
        }
        if isArchivedClaudeDesktopSession(data, archivedSessionIDs: evidence.archivedClaudeSessionIDs) {
            return .hidden(.archivedClaudeDesktop)
        }
        // Claude Desktop `SessionEnd` is worker/session termination, not archive; matched metadata stays resumable.
        if isOrphanedEndedClaudeDesktopSession(data, metadataSnapshot: claudeMetadata) {
            return .hidden(.orphanedEndedClaudeDesktop)
        }
        if isClaudeDesktopStartupPlaceholder(data, metadataSnapshot: claudeMetadata) {
            return .hidden(.claudeDesktopStartupPlaceholder)
        }
        return .display
    }

    func deriveSessionClassification(from decoded: [(url: URL, session: SessionData)]) -> SessionClassificationSnapshot {
        let now = dataSources.now()
        let codexThreads = batchedCodexThreadState(
            in: decoded.map(\.session),
            codexThreads: dataSources.codexThreads
        )
        let repaired = repairStickyCodexDelegationState(in: decoded, codexThreads: codexThreads)
        let classifiableSessions = repaired
            .map(\.session)
            .filter { !$0.hidden && !$0.shouldAutoHide }
        let claudeMetadata = Self.claudeDesktopMetadataSnapshot(
            in: classifiableSessions,
            claudeDesktopSessions: dataSources.claudeDesktopSessions
        )
        let candidates = Self.buildCandidates(
            repaired,
            now: now,
            desktopAppConnectionLookup: dataSources.desktopAppConnection,
            claudeMetadata: claudeMetadata,
            processAlive: dataSources.processAlive
        )
        return Self.sessionClassificationSnapshot(
            in: candidates,
            sessions: repaired.map(\.session),
            claudeMetadata: claudeMetadata,
            codexThreads: codexThreads,
            now: now
        )
    }

    private func repairStickyCodexDelegationState(
        in decoded: [(url: URL, session: SessionData)],
        codexThreads: FrozenCodexThreadState
    ) -> [(url: URL, session: SessionData)] {
        guard let index = codexThreads.index else { return decoded }
        let repairableThreadIDs = index.interactiveRootThreadIDs
            .intersection(index.knownNoSpawnEdgeThreadIDs)
        guard !repairableThreadIDs.isEmpty else { return decoded }

        var repairedByPath: [String: SessionData] = [:]
        for (url, data) in decoded where data.hidden
            && data.isSubagentSession
            && repairableThreadIDs.contains(data.sessionId) {
            withSessionLockForMaintenance(
                sessionPath: url.path,
                sessionId: data.sessionId,
                action: "Codex delegated-task classification repair"
            ) {
                guard let repaired = try Self.repairedCodexInteractiveRootSessionSnapshot(
                    path: url.path,
                    repairableThreadIDs: repairableThreadIDs
                ) else {
                    return
                }
                try repaired.writeToFile(path: url.path)
                repairedByPath[url.path] = repaired
                sessionManagerLogger.info(
                    "restoring interactive Codex session \(data.sessionId, privacy: .public)"
                )
            }
        }

        return decoded.map { entry in
            (entry.url, repairedByPath[entry.url.path] ?? entry.session)
        }
    }

    private func batchedCodexThreadState(
        in sessions: [SessionData],
        codexThreads: any CodexThreadStateProviding
    ) -> FrozenCodexThreadState {
        let threadIDs = Self.codexThreadIDs(in: sessions)
        let snapshot = codexThreads.stateSnapshot(matching: threadIDs)
        let effectiveIndex = codexThreadClassificationMemory.effectiveIndex(
            from: snapshot,
            matching: threadIDs
        )
        return FrozenCodexThreadState(index: effectiveIndex)
    }

    private nonisolated static func codexThreadIDs(in sessions: [SessionData]) -> Set<String> {
        Set(
            sessions
                .filter(\.isCodex)
                .map(\.sessionId)
        )
    }

    /// Codex sessions should correspond to a Codex thread row. If the thread store is
    /// readable and the row is gone, the app should not publish the stale hook session.
    private nonisolated static func missingCodexThreadIDs(
        in sessions: [SessionData],
        index: CodexThreadStateIndex?,
        now: Date
    ) -> Set<String> {
        guard let index else { return [] }
        let codexSessions = sessions.filter(\.isCodex)
        let threadIDs = Set(codexSessions.map(\.sessionId))
        let resolvedThreadIDs = threadIDs.subtracting(index.unknownThreadIDs)
        let missingThreadIDs = resolvedThreadIDs.subtracting(index.existingThreadIDs)
        let freshMissingThreadIDs = Set(codexSessions.compactMap { session -> String? in
            guard missingThreadIDs.contains(session.sessionId),
                  now.timeIntervalSince(session.lastActivity) <= Self.codexMissingThreadGraceSeconds else {
                return nil
            }
            return session.sessionId
        })
        return missingThreadIDs.subtracting(freshMissingThreadIDs)
    }

    nonisolated static func isMissingCodexSession(
        _ session: SessionData,
        missingThreadIDs: Set<String>
    ) -> Bool {
        session.isCodex && missingThreadIDs.contains(session.sessionId)
    }

    nonisolated static func isCodexInternalHelperSession(
        _ session: SessionData,
        internalHelperThreadIDs: Set<String>
    ) -> Bool {
        session.isCodex && internalHelperThreadIDs.contains(session.sessionId)
    }

    /// Codex can launch short-lived `codex exec` helper threads. They are useful as
    /// rollout artifacts but should not appear as user-visible cctop sessions.
    private nonisolated static func codexExecHelperThreadIDs(
        in sessions: [SessionData],
        index: CodexThreadStateIndex?
    ) -> Set<String> {
        let threadIDs = codexThreadIDs(in: sessions)
        return index?.execHelperThreadIDs.intersection(threadIDs) ?? []
    }

    nonisolated static func isCodexExecHelperSession(
        _ session: SessionData,
        execHelperThreadIDs: Set<String>
    ) -> Bool {
        session.isCodex && execHelperThreadIDs.contains(session.sessionId)
    }

    /// Re-read the session file under its lock before persisting a hidden flag. The helper IDs
    /// come from the same batched authoritative snapshot used for classification, avoiding a
    /// second database query per session while still rejecting a concurrently replaced file.
    nonisolated static func codexInternalHelperHiddenSessionSnapshot(
        path: String,
        internalHelperThreadIDs: Set<String>
    ) throws -> SessionData? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var latest = try SessionData.fromFile(path: path)
        guard !latest.hidden, latest.isCodex else { return nil }
        guard internalHelperThreadIDs.contains(latest.sessionId) else { return nil }
        latest.isSubagentSession = true
        latest.hidden = true
        return latest
    }

    /// Repairs only the stale marker pair written by the old `thread_source` classifier. The
    /// caller supplies a batched, authoritative set that has already proven `cli`/`vscode` and
    /// a readable topology table with no spawn edge.
    nonisolated static func repairedCodexInteractiveRootSessionSnapshot(
        path: String,
        repairableThreadIDs: Set<String>
    ) throws -> SessionData? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var latest = try SessionData.fromFile(path: path)
        guard latest.hidden,
              latest.isSubagentSession,
              latest.isCodex,
              repairableThreadIDs.contains(latest.sessionId) else {
            return nil
        }

        latest.isSubagentSession = false
        guard !latest.shouldAutoHide else { return nil }
        latest.hidden = false
        return latest
    }

    nonisolated static func autoHiddenSessionSnapshot(path: String) throws -> SessionData? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var latest = try SessionData.fromFile(path: path)
        guard !latest.hidden, latest.shouldAutoHide else { return nil }
        latest.hidden = true
        return latest
    }

    func hideCodexInternalHelperSessions(_ candidates: [SessionRecord]) {
        let internalHelperThreadIDs = Set(candidates.map(\.data.sessionId))
        for candidate in candidates {
            withSessionLockForMaintenance(
                sessionPath: candidate.path,
                sessionId: candidate.data.sessionId,
                action: "Codex internal helper hide"
            ) {
                guard let hiddenSession = try Self.codexInternalHelperHiddenSessionSnapshot(
                    path: candidate.path,
                    internalHelperThreadIDs: internalHelperThreadIDs
                ) else {
                    return
                }
                sessionManagerLogger.info(
                    "hiding Codex internal helper session \(candidate.data.sessionId, privacy: .public)"
                )
                try hiddenSession.writeToFile(path: candidate.path)
            }
        }
    }

    nonisolated static func claudeDesktopMetadataSnapshot(
        in sessions: [SessionData],
        claudeDesktopSessions: any ClaudeDesktopSessionStateProviding = ClaudeDesktopSessionArchiveLookup()
    ) -> ClaudeDesktopSessionMetadataSnapshot? {
        let sessionIDs = Set(
            sessions
                .filter(\.isClaudeDesktopHost)
                .map(\.sessionId)
        )
        return claudeDesktopSessions.metadataSnapshot(matching: sessionIDs)
    }

    nonisolated static func isArchivedClaudeDesktopSession(
        _ session: SessionData,
        archivedSessionIDs: Set<String>
    ) -> Bool {
        session.isClaudeDesktopHost && archivedSessionIDs.contains(session.sessionId)
    }

    nonisolated static func isOrphanedEndedClaudeDesktopSession(
        _ session: SessionData,
        metadataSnapshot: ClaudeDesktopSessionMetadataSnapshot?
    ) -> Bool {
        guard session.isClaudeDesktopHost,
              session.endedAt != nil || session.disconnectedAt != nil,
              metadataSnapshot?.isAuthoritative == true else {
            return false
        }
        return metadataSnapshot?.matchedSessionIDs.contains(session.sessionId) == false
    }

    nonisolated static func isClaudeDesktopStartupPlaceholder(
        _ session: SessionData,
        metadataSnapshot: ClaudeDesktopSessionMetadataSnapshot?
    ) -> Bool {
        guard session.isClaudeDesktopHost,
              session.endedAt == nil, session.disconnectedAt == nil,
              metadataSnapshot?.isAuthoritative == true, metadataSnapshot?.matchedSessionIDs.contains(session.sessionId) == false,
              session.status == .idle,
              isBlank(session.sessionName),
              isBlank(session.lastPrompt),
              isBlank(session.lastTool),
              isBlank(session.lastToolDetail),
              isBlank(session.notificationMessage),
              session.activeSubagents?.isEmpty ?? true else {
            return false
        }
        return true
    }
    private nonisolated static func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}
