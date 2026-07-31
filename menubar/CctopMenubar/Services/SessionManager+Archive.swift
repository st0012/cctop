// swiftlint:disable file_length
import Foundation

/// The external inputs SessionManager consults while deriving session state: the sessions
/// directory, the Codex/Claude Desktop archive stores, desktop-app liveness, process liveness,
/// notification and manual-visibility preferences, and the clock. Production uses `.live()`; tests override
/// individual fields to run the full pipeline against temp directories, stub lookups, and a
/// deterministic clock. One state-deriving input remains outside this seam:
/// `adjustPermissionStatus` probes the live process tree (`proc_listchildpids`) directly.
struct SessionDataSources {
    var sessionsDir: URL
    var codexThreads: any CodexThreadStateProviding
    var claudeDesktopSessions: any ClaudeDesktopSessionStateProviding
    var desktopAppConnection: DesktopAppConnectionLookup
    var processAlive: (Session) -> Bool
    var notificationsEnabled: () -> Bool
    var notificationClient: SessionNotificationClient = .live
    var manualSessionVisibility: ManualSessionVisibilityStore = .live
    var now: () -> Date

    /// A function rather than a stored constant so `Config.sessionsDir()` is resolved
    /// when the caller constructs its sources. The live metadata stores resolve their
    /// own paths as needed, with short internal caches for repeated reads in one pass.
    static func live() -> SessionDataSources {
        SessionDataSources(
            sessionsDir: URL(fileURLWithPath: Config.sessionsDir()),
            codexThreads: CodexThreadArchiveLookup(),
            claudeDesktopSessions: ClaudeDesktopSessionArchiveLookup(),
            desktopAppConnection: .live,
            processAlive: { $0.isAlive },
            notificationsEnabled: { UserDefaults.standard.bool(forKey: "notificationsEnabled") },
            now: Date.init
        )
    }
}

struct SessionClassificationEvidence {
    let archivedCodexThreadIDs: Set<String>
    let missingCodexDesktopThreadIDs: Set<String>
    let codexInternalHelperThreadIDs: Set<String>
    let uncertainCodexDelegationThreadIDs: Set<String>
    let contradictoryCodexDelegationThreadIDs: Set<String>
    let codexExecHelperThreadIDs: Set<String>
    let archivedClaudeSessionIDs: Set<String>
}

struct FrozenCodexThreadState: CodexThreadStateProviding {
    let index: CodexThreadStateIndex?

    func stateIndex(matching threadIDs: Set<String>) -> CodexThreadStateIndex? {
        guard let index else { return nil }
        return index.filtered(to: threadIDs)
    }

    func existingThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        guard let index, index.unknownThreadIDs.isDisjoint(with: threadIDs) else {
            return nil
        }
        return index.existingThreadIDs.intersection(threadIDs)
    }

    func archivedThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        guard let index else { return [] }
        guard index.unknownThreadIDs.isDisjoint(with: threadIDs) else {
            return nil
        }
        return index.archivedThreadIDs.intersection(threadIDs)
    }

    func internalHelperThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        index.map { $0.internalHelperThreadIDs.intersection(threadIDs) } ?? []
    }

    func execHelperThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        index.map { $0.execHelperThreadIDs.intersection(threadIDs) } ?? []
    }

    func projectNames(matching threadIDs: Set<String>) -> [String: String]? {
        index.map { $0.projectNamesByThreadID.filter { threadIDs.contains($0.key) } }
    }
}

enum SessionHiddenReason: Equatable {
    case persistedHidden
    case autoHidden
    case archivedCodexDesktop
    case missingCodexDesktopThread
    case codexInternalHelper
    case codexExecHelper
    case archivedClaudeDesktop
    case orphanedEndedClaudeDesktop
    case claudeDesktopStartupPlaceholder

    /// Hidden helper/subagent records still represent live ownership of the path, so they
    /// protect cleanup. Archived/deleted desktop records are hidden UI state instead; only
    /// explicitly emitted cleanup sources can make those paths cleanup candidates.
    var protectsCleanupPath: Bool {
        switch self {
        case .persistedHidden, .autoHidden, .codexInternalHelper, .codexExecHelper:
            return true
        case .archivedCodexDesktop, .missingCodexDesktopThread, .archivedClaudeDesktop,
             .orphanedEndedClaudeDesktop, .claudeDesktopStartupPlaceholder:
            return false
        }
    }
}

enum SessionDisposition: Equatable {
    case display
    case hidden(SessionHiddenReason)
}

struct ClassifiedSessionRecord {
    let url: URL
    let candidate: DedupCandidate
    let disposition: SessionDisposition
}

struct SessionClassificationSnapshot {
    let records: [ClassifiedSessionRecord]
    let evidence: SessionClassificationEvidence

    var displayCandidates: [DedupCandidate] {
        records.compactMap { record in
            guard record.disposition == .display else { return nil }
            return record.candidate
        }
    }

    var autoHiddenSessions: [(URL, Session)] {
        records.compactMap { record in
            guard case .hidden(.autoHidden) = record.disposition else { return nil }
            return (record.url, record.candidate.session)
        }
    }

    var codexInternalHelperCandidates: [DedupCandidate] {
        records.compactMap { record in
            guard case .hidden(.codexInternalHelper) = record.disposition else { return nil }
            return record.candidate
        }
    }

    var protectedProjectPathsForCleanup: Set<String> {
        let displayProtected = SessionIdentityPolicy
            .dedupedCandidatesByStableKey(displayCandidates)
            .filter { $0.lifecycleRank != SessionLifecycle.finished.rawValue }
            .map(\.session.projectPath)
        let hiddenProtected = records.compactMap { record -> String? in
            guard case .hidden(let reason) = record.disposition,
                  reason.protectsCleanupPath,
                  record.candidate.lifecycleRank != SessionLifecycle.finished.rawValue else {
                return nil
            }
            return record.candidate.session.projectPath
        }
        return Set(displayProtected).union(hiddenProtected)
    }

    var finishedNonDesktopCandidates: [DedupCandidate] {
        displayCandidates.filter {
            $0.lifecycleRank == SessionLifecycle.finished.rawValue && $0.session.hostClass != .desktop
        }
    }

    func manualHiddenProjectPaths(_ hiddenSessionIDs: Set<String>) -> Set<String> {
        Set(records.compactMap { record in
            guard let cctopSessionID = record.candidate.session.cctopSessionId,
                  hiddenSessionIDs.contains(cctopSessionID) else { return nil }
            return record.candidate.session.projectPath
        })
    }

    /// Archived desktop conversations stay hidden and resumable in Recent, but a known
    /// project path can still seed worktree cleanup while preserving the session file.
    /// Non-desktop cleanup rows come from history.
    var cleanupSources: [SessionCleanupSource] {
        records.compactMap { record in
            guard case .hidden(let reason) = record.disposition,
                  reason.emitsCleanupSource,
                  record.candidate.session.hasCleanupSourcePath else {
                return nil
            }
            return SessionCleanupSource(session: record.candidate.session)
        }
    }

    var archivedCodexThreadIDs: Set<String> { evidence.archivedCodexThreadIDs }
    var missingCodexDesktopThreadIDs: Set<String> { evidence.missingCodexDesktopThreadIDs }
    var codexInternalHelperThreadIDs: Set<String> { evidence.codexInternalHelperThreadIDs }
    var uncertainCodexDelegationThreadIDs: Set<String> { evidence.uncertainCodexDelegationThreadIDs }
    var contradictoryCodexDelegationThreadIDs: Set<String> { evidence.contradictoryCodexDelegationThreadIDs }
    var codexExecHelperThreadIDs: Set<String> { evidence.codexExecHelperThreadIDs }
    var archivedClaudeSessionIDs: Set<String> { evidence.archivedClaudeSessionIDs }
}

private extension SessionHiddenReason {
    var emitsCleanupSource: Bool {
        switch self {
        case .archivedCodexDesktop, .archivedClaudeDesktop:
            return true
        case .persistedHidden, .autoHidden, .missingCodexDesktopThread, .codexInternalHelper,
             .codexExecHelper, .orphanedEndedClaudeDesktop, .claudeDesktopStartupPlaceholder:
            return false
        }
    }
}

private extension Session {
    var hasCleanupSourcePath: Bool {
        let path = WorktreeCleanupScanner.standardizedPath(projectPath)
        return !path.isEmpty && path != "/"
    }
}

extension SessionManager {
    func retainedFinishedCleanupSources(
        winners: [DedupCandidate],
        unresolvedLegacyKeys: Set<String>,
        unresolvedLegacyEvidence: Set<String>
    ) -> [SessionCleanupSource] {
        winners.compactMap { candidate in
            let session = candidate.session
            guard candidate.lifecycleRank == SessionLifecycle.finished.rawValue,
                  shouldRetainFinishedManualHideEvidence(
                      session,
                      legacyKeys: unresolvedLegacyKeys,
                      legacyEvidence: unresolvedLegacyEvidence
                  ),
                  session.hasCleanupSourcePath else {
                return nil
            }
            return SessionCleanupSource(session: session)
        }
    }

    func archiveAndRemoveFinishedNonDesktop(
        _ candidates: [DedupCandidate],
        winners: [DedupCandidate],
        unresolvedLegacyKeys: Set<String>,
        unresolvedLegacyEvidence: Set<String>
    ) -> [SessionCleanupSource] {
        let winnerPaths = Set(winners.map(\.path))
        var newlyArchivedCleanupSources: [SessionCleanupSource] = []
        for candidate in candidates {
            guard !shouldRetainFinishedManualHideEvidence(
                candidate.session,
                legacyKeys: unresolvedLegacyKeys,
                legacyEvidence: unresolvedLegacyEvidence
            ) else { continue }
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
        _ session: Session,
        legacyKeys: Set<String>,
        legacyEvidence: Set<String>
    ) -> Bool {
        shouldRetainManualHideEvidence(session, legacyKeys: legacyKeys, legacyEvidence: legacyEvidence)
            || hasExistingMappedManualHide(session)
    }

    func hasExistingMappedManualHide(_ session: Session) -> Bool {
        guard !Session.isValidCctopSessionId(session.cctopSessionId) else { return false }
        let hiddenSessionIDs = dataSources.manualSessionVisibility.hiddenSessionIDs
        guard !hiddenSessionIDs.isEmpty,
              let existingID = try? CctopSessionIdentityStore(sessionsDir: dataSources.sessionsDir).existingIdentity(
                  source: session.source,
                  harnessSessionId: session.harnessSessionId,
                  legacySessionId: session.sessionId
              ) else {
            return false
        }
        return hiddenSessionIDs.contains(existingID)
    }

    func shouldRetainManualHideEvidence(
        _ session: Session,
        legacyKeys: Set<String>,
        legacyEvidence: Set<String>
    ) -> Bool {
        dataSources.manualSessionVisibility.isHidden(session)
            || legacyKeys.contains(SessionIdentityPolicy.stableKey(for: session))
            || CctopSessionIdentityStore.durableEvidence(
                source: session.source,
                harnessSessionId: session.harnessSessionId,
                legacySessionId: session.sessionId
            ).map(legacyEvidence.contains) == true
    }

    func sweepLegacyUUIDFileIfNeeded(
        _ url: URL,
        unresolvedLegacyKeys: Set<String>,
        unresolvedLegacyEvidence: Set<String>
    ) -> Bool {
        guard Self.isLegacyUUIDFilename(url.deletingPathExtension().lastPathComponent) else { return false }
        if !dataSources.manualSessionVisibility.hasStoredHideEvidence {
            try? FileManager.default.removeItem(at: url) // Pre-PID legacy file; no live writer to race.
        } else if let data = try? Data(contentsOf: url),
                  let session = try? JSONDecoder.sessionDecoder.decode(Session.self, from: data),
                  !shouldRetainFinishedManualHideEvidence(
                      session,
                      legacyKeys: unresolvedLegacyKeys,
                      legacyEvidence: unresolvedLegacyEvidence
                  ) {
            try? FileManager.default.removeItem(at: url)
        }
        return true
    }

    func unresolvedManualHideEvidence(in sessions: [Session], legacyKeys: Set<String>) -> Set<String> {
        var evidence = Set(legacyKeys.compactMap {
            ManualSessionVisibilityStore.durableEvidence(forLegacyKey: $0)
        })
        evidence.formUnion(sessions
            .filter { legacyKeys.contains(SessionIdentityPolicy.stableKey(for: $0)) }
            .compactMap {
                CctopSessionIdentityStore.durableEvidence(
                    source: $0.source,
                    harnessSessionId: $0.harnessSessionId,
                    legacySessionId: $0.sessionId
                )
            })
        return evidence
    }

    func unresolvedManualHideEvidence(in files: [URL], legacyKeys: Set<String>) -> Set<String> {
        unresolvedManualHideEvidence(
            in: files.compactMap { url in
                (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.sessionDecoder.decode(Session.self, from: $0) }
            },
            legacyKeys: legacyKeys
        )
    }

    func mergingCleanupSources(
        _ retained: [SessionCleanupSource],
        with replacements: [SessionCleanupSource]
    ) -> [SessionCleanupSource] {
        retained.filter { source in
            !replacements.contains {
                $0.sessionId == source.sessionId && $0.projectPath == source.projectPath
            }
        } + replacements
    }

    private func archiveAndRemove(_ candidate: DedupCandidate) -> SessionCleanupSource? {
        let session = candidate.session
        // A dead non-desktop process holds no lock, so removing its .json needs no flock. Remove
        // the .json ONLY — never the .lock (unlinking a lock a hook still holds splits the inode).
        if historyManager.archiveSession(session) {
            try? FileManager.default.removeItem(atPath: candidate.path)
            return session.hasCleanupSourcePath ? SessionCleanupSource(session: session) : nil
        } else {
            sessionManagerLogger.warning("skipping removal of \(session.sessionId, privacy: .public) — archive failed")
            return nil
        }
    }

    private func removeStaleDuplicate(_ candidate: DedupCandidate) {
        sessionManagerLogger.info("removing stale duplicate session file \(candidate.path, privacy: .public)")
        try? FileManager.default.removeItem(atPath: candidate.path)
    }

    nonisolated static func desktopAppRunningByBundleID(
        in sessions: [Session],
        lookup: DesktopAppConnectionLookup
    ) -> [String: Bool] {
        let bundleIDs = Set(sessions.compactMap { session -> String? in
            guard session.hostClass == .desktop else { return nil }
            return session.terminal?.bundleId
        })
        return lookup.runningStates(bundleIDs)
    }

    nonisolated static func desktopAppRunning(
        for session: Session,
        runningByBundleID: [String: Bool]
    ) -> Bool? {
        guard session.hostClass == .desktop,
              let bundleID = session.terminal?.bundleId else {
            return nil
        }
        return runningByBundleID[bundleID]
    }

    nonisolated static func desktopAppRunning(
        for session: Session,
        lookup: DesktopAppConnectionLookup
    ) -> Bool? {
        guard session.hostClass == .desktop,
              let bundleID = session.terminal?.bundleId else {
            return nil
        }
        return lookup.isRunning(bundleID)
    }

    func preloadDesktopArchiveStateForFinishedSessions(
        in jsonFiles: [URL],
        now: Date
    ) {
        var finished: [Session] = []
        for url in jsonFiles {
            guard !Self.isLegacyUUIDFilename(url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url),
                  let session = try? JSONDecoder.sessionDecoder.decode(Session.self, from: data),
                  !session.hidden,
                  !session.shouldAutoHide,
                  session.hostClass == .desktop else {
                continue
            }
            let life = SessionLifecyclePolicy.lifecycle(
                for: session,
                hostClass: .desktop,
                processAlive: dataSources.processAlive(session),
                now: now,
                windows: Self.lifecycleWindows,
                desktopAppRunning: Self.desktopAppRunning(for: session, lookup: dataSources.desktopAppConnection)
            )
            if life == .finished {
                finished.append(session)
            }
        }

        let codexFinishedIDs = Set(finished.filter(\.isCodexDesktopHost).map(\.sessionId))
        let claudeFinishedIDs = Set(finished.filter(\.isClaudeDesktopHost).map(\.sessionId))
        if !codexFinishedIDs.isEmpty {
            _ = dataSources.codexThreads.archivedThreadIDs(matching: codexFinishedIDs)
        }
        if !claudeFinishedIDs.isEmpty {
            _ = dataSources.claudeDesktopSessions.archivedSessionIDs(matching: claudeFinishedIDs)
        }
    }

    nonisolated static func sessionClassificationSnapshot(
        in candidates: [DedupCandidate],
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup(),
        claudeDesktopSessions: any ClaudeDesktopSessionStateProviding = ClaudeDesktopSessionArchiveLookup(),
        now: Date = Date()
    ) -> SessionClassificationSnapshot {
        let sessions = candidates.map(\.session)
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
        in candidates: [DedupCandidate],
        claudeMetadata: ClaudeDesktopSessionMetadataSnapshot?,
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup(),
        now: Date = Date()
    ) -> SessionClassificationSnapshot {
        sessionClassificationSnapshot(
            in: candidates,
            sessions: candidates.map(\.session),
            claudeMetadata: claudeMetadata,
            codexThreads: codexThreads,
            now: now
        )
    }

    private nonisolated static func sessionClassificationSnapshot(
        in candidates: [DedupCandidate],
        sessions: [Session],
        claudeMetadata: ClaudeDesktopSessionMetadataSnapshot?,
        codexThreads: any CodexThreadStateProviding,
        now: Date
    ) -> SessionClassificationSnapshot {
        let externallyClassifiableSessions = sessions.filter { !$0.hidden && !$0.shouldAutoHide }
        let codexDelegationIndex = codexThreads.stateIndex(
            matching: codexThreadIDs(in: sessions)
        )
        let archivedCodexThreadIDs = archivedCodexDesktopThreadIDs(
            in: externallyClassifiableSessions,
            index: codexDelegationIndex
        )
        let missingCodexDesktopThreadIDs = missingCodexDesktopThreadIDs(
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
            missingCodexDesktopThreadIDs: missingCodexDesktopThreadIDs,
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
                    for: candidate.session,
                    evidence: evidence,
                    claudeMetadata: claudeMetadata
                )
            )
        }
        return SessionClassificationSnapshot(records: records, evidence: evidence)
    }

    private nonisolated static func disposition(
        for session: Session,
        evidence: SessionClassificationEvidence,
        claudeMetadata: ClaudeDesktopSessionMetadataSnapshot?
    ) -> SessionDisposition {
        // Priority is behavior-bearing: durable local hides win first, then host archive/missing
        // decisions, then helper/subagent filters, then Claude Desktop placeholder/orphan filters.
        if session.hidden {
            return .hidden(.persistedHidden)
        }
        if session.shouldAutoHide {
            return .hidden(.autoHidden)
        }
        if isArchivedCodexDesktopSession(session, archivedThreadIDs: evidence.archivedCodexThreadIDs) {
            return .hidden(.archivedCodexDesktop)
        }
        if isMissingCodexDesktopSession(session, missingThreadIDs: evidence.missingCodexDesktopThreadIDs) {
            return .hidden(.missingCodexDesktopThread)
        }
        if isCodexInternalHelperSession(session, internalHelperThreadIDs: evidence.codexInternalHelperThreadIDs) {
            return .hidden(.codexInternalHelper)
        }
        if isCodexExecHelperSession(session, execHelperThreadIDs: evidence.codexExecHelperThreadIDs) {
            return .hidden(.codexExecHelper)
        }
        if isArchivedClaudeDesktopSession(session, archivedSessionIDs: evidence.archivedClaudeSessionIDs) {
            return .hidden(.archivedClaudeDesktop)
        }
        // Claude Desktop `SessionEnd` is worker/session termination, not archive; matched metadata stays resumable.
        if isOrphanedEndedClaudeDesktopSession(session, metadataSnapshot: claudeMetadata) {
            return .hidden(.orphanedEndedClaudeDesktop)
        }
        if isClaudeDesktopStartupPlaceholder(session, metadataSnapshot: claudeMetadata) {
            return .hidden(.claudeDesktopStartupPlaceholder)
        }
        return .display
    }

    func deriveSessionClassification(from decoded: [(url: URL, session: Session)]) -> SessionClassificationSnapshot {
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
            codexThreads: codexThreads,
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
        in decoded: [(url: URL, session: Session)],
        codexThreads: FrozenCodexThreadState
    ) -> [(url: URL, session: Session)] {
        guard let index = codexThreads.index else { return decoded }
        let repairableThreadIDs = index.interactiveRootThreadIDs
            .intersection(index.knownNoSpawnEdgeThreadIDs)
        guard !repairableThreadIDs.isEmpty else { return decoded }

        var repairedByPath: [String: Session] = [:]
        for (url, session) in decoded where session.hidden
            && session.isSubagentSession
            && repairableThreadIDs.contains(session.sessionId) {
            withSessionLockForMaintenance(
                sessionPath: url.path,
                sessionId: session.sessionId,
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
                    "restoring interactive Codex session \(session.sessionId, privacy: .public)"
                )
            }
        }

        return decoded.map { entry in
            (entry.url, repairedByPath[entry.url.path] ?? entry.session)
        }
    }

    private func batchedCodexThreadState(
        in sessions: [Session],
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

    private nonisolated static func codexThreadIDs(in sessions: [Session]) -> Set<String> {
        Set(
            sessions
                .filter { $0.isCodex || $0.isCodexDesktopHost }
                .map(\.sessionId)
        )
    }

    private nonisolated static func archivedCodexDesktopThreadIDs(
        in sessions: [Session],
        index: CodexThreadStateIndex?
    ) -> Set<String> {
        let threadIDs = Set(sessions.filter(\.isCodexDesktopHost).map(\.sessionId))
        return index?.archivedThreadIDs.intersection(threadIDs) ?? []
    }

    nonisolated static func isArchivedCodexDesktopSession(
        _ session: Session,
        archivedThreadIDs: Set<String>
    ) -> Bool {
        session.isCodexDesktopHost && archivedThreadIDs.contains(session.sessionId)
    }

    /// Codex Desktop sessions should correspond to a Codex thread row. If the thread store is
    /// readable and the row is gone, the app should not publish the stale hook session.
    private nonisolated static func missingCodexDesktopThreadIDs(
        in sessions: [Session],
        index: CodexThreadStateIndex?,
        now: Date
    ) -> Set<String> {
        guard let index else { return [] }
        let codexDesktopSessions = sessions.filter { $0.source == Session.codexSource && $0.isCodexDesktopHost }
        let threadIDs = Set(codexDesktopSessions.map(\.sessionId))
        let resolvedThreadIDs = threadIDs.subtracting(index.unknownThreadIDs)
        let missingThreadIDs = resolvedThreadIDs.subtracting(index.existingThreadIDs)
        let freshMissingThreadIDs = Set(codexDesktopSessions.compactMap { session -> String? in
            guard missingThreadIDs.contains(session.sessionId),
                  now.timeIntervalSince(session.lastActivity) <= Self.codexMissingThreadGraceSeconds else {
                return nil
            }
            return session.sessionId
        })
        return missingThreadIDs.subtracting(freshMissingThreadIDs)
    }

    nonisolated static func isMissingCodexDesktopSession(
        _ session: Session,
        missingThreadIDs: Set<String>
    ) -> Bool {
        session.source == Session.codexSource
            && session.isCodexDesktopHost
            && missingThreadIDs.contains(session.sessionId)
    }

    nonisolated static func isCodexInternalHelperSession(
        _ session: Session,
        internalHelperThreadIDs: Set<String>
    ) -> Bool {
        (session.isCodex || session.isCodexDesktopHost) && internalHelperThreadIDs.contains(session.sessionId)
    }

    /// Codex Desktop can launch short-lived `codex exec` helper threads. They are useful as
    /// rollout artifacts but should not appear as user-visible cctop sessions.
    private nonisolated static func codexExecHelperThreadIDs(
        in sessions: [Session],
        index: CodexThreadStateIndex?
    ) -> Set<String> {
        let threadIDs = codexThreadIDs(in: sessions)
        return index?.execHelperThreadIDs.intersection(threadIDs) ?? []
    }

    nonisolated static func isCodexExecHelperSession(
        _ session: Session,
        execHelperThreadIDs: Set<String>
    ) -> Bool {
        (session.isCodex || session.isCodexDesktopHost) && execHelperThreadIDs.contains(session.sessionId)
    }

    /// Re-read the session file under its lock before persisting a hidden flag. The helper IDs
    /// come from the same batched authoritative snapshot used for classification, avoiding a
    /// second database query per session while still rejecting a concurrently replaced file.
    nonisolated static func codexInternalHelperHiddenSessionSnapshot(
        path: String,
        internalHelperThreadIDs: Set<String>
    ) throws -> Session? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var latest = try Session.fromFile(path: path)
        guard !latest.hidden, latest.isCodex || latest.isCodexDesktopHost else { return nil }
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
    ) throws -> Session? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var latest = try Session.fromFile(path: path)
        guard latest.hidden,
              latest.isSubagentSession,
              latest.isCodex || latest.isCodexDesktopHost,
              repairableThreadIDs.contains(latest.sessionId) else {
            return nil
        }

        latest.isSubagentSession = false
        guard !latest.shouldAutoHide else { return nil }
        latest.hidden = false
        return latest
    }

    nonisolated static func autoHiddenSessionSnapshot(path: String) throws -> Session? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var latest = try Session.fromFile(path: path)
        guard !latest.hidden, latest.shouldAutoHide else { return nil }
        latest.hidden = true
        return latest
    }

    func hideCodexInternalHelperSessions(_ candidates: [DedupCandidate]) {
        let internalHelperThreadIDs = Set(candidates.map(\.session.sessionId))
        for candidate in candidates {
            withSessionLockForMaintenance(
                sessionPath: candidate.path,
                sessionId: candidate.session.sessionId,
                action: "Codex internal helper hide"
            ) {
                guard let hiddenSession = try Self.codexInternalHelperHiddenSessionSnapshot(
                    path: candidate.path,
                    internalHelperThreadIDs: internalHelperThreadIDs
                ) else {
                    return
                }
                sessionManagerLogger.info(
                    "hiding Codex internal helper session \(candidate.session.sessionId, privacy: .public)"
                )
                try hiddenSession.writeToFile(path: candidate.path)
            }
        }
    }

    nonisolated static func claudeDesktopMetadataSnapshot(
        in sessions: [Session],
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
        _ session: Session,
        archivedSessionIDs: Set<String>
    ) -> Bool {
        session.isClaudeDesktopHost && archivedSessionIDs.contains(session.sessionId)
    }

    nonisolated static func isOrphanedEndedClaudeDesktopSession(
        _ session: Session,
        metadataSnapshot: ClaudeDesktopSessionMetadataSnapshot?
    ) -> Bool {
        guard session.isClaudeDesktopHost,
              session.endedAt != nil || session.disconnectedAt != nil,
              metadataSnapshot?.isAuthoritative == true else {
            return false
        }
        return metadataSnapshot?.matchedSessionIDs.contains(session.sessionId) == false
    }

    nonisolated static func isClaudeDesktopStartupPlaceholder(_ session: Session, metadataSnapshot: ClaudeDesktopSessionMetadataSnapshot?) -> Bool {
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

    /// Fresh single-session archive check for the GC deletion decision. Unlike the batch snapshot
    /// `loadSessions` uses, this re-reads Codex thread state at call time, including rollout
    /// placement when available, so a thread archived after the GC directory scan is never deleted
    /// out from under a pending unarchive. When the store exists but cannot be read, the lookup
    /// returns nil and we fail SAFE.
    nonisolated static func isCodexDesktopThreadArchived(
        _ session: Session,
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup()
    ) -> Bool {
        guard session.isCodexDesktopHost else { return false }
        guard let archived = codexThreads.archivedThreadIDs(matching: [session.sessionId]) else {
            return true
        }
        return archived.contains(session.sessionId)
    }

    /// Fresh single-session archive check for Claude Desktop's GC deletion decision. Missing
    /// metadata means "not archived"; unreadable matching metadata means "unknown" and keeps the
    /// file.
    nonisolated static func isClaudeDesktopSessionArchived(
        _ session: Session,
        claudeDesktopSessions: any ClaudeDesktopSessionStateProviding = ClaudeDesktopSessionArchiveLookup()
    ) -> Bool {
        guard session.isClaudeDesktopHost else { return false }
        guard let archived = claudeDesktopSessions.archivedSessionIDs(matching: [session.sessionId]) else {
            return true
        }
        return archived.contains(session.sessionId)
    }

    nonisolated static func isArchivedDesktopSession(
        _ session: Session,
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup(),
        claudeDesktopSessions: any ClaudeDesktopSessionStateProviding = ClaudeDesktopSessionArchiveLookup()
    ) -> Bool {
        isCodexDesktopThreadArchived(session, codexThreads: codexThreads)
            || isClaudeDesktopSessionArchived(session, claudeDesktopSessions: claudeDesktopSessions)
    }

    /// Decode each session file, derive its lifecycle, and capture mtime — the inputs the dedup
    /// comparator needs. Pure (no published state), kept off the main class body.
    nonisolated static func buildCandidates(
        _ sessionFiles: [(url: URL, session: Session)],
        now: Date,
        desktopAppConnectionLookup: DesktopAppConnectionLookup = .live,
        claudeMetadata: ClaudeDesktopSessionMetadataSnapshot?,
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup(),
        processAlive: (Session) -> Bool = { $0.isAlive }
    ) -> [DedupCandidate] {
        let projectNames = desktopProjectNamesBySessionID(
            in: sessionFiles.map(\.session),
            claudeMetadata: claudeMetadata,
            codexThreads: codexThreads
        )
        let desktopAppRunningByBundleID = desktopAppRunningByBundleID(
            in: sessionFiles.map(\.session),
            lookup: desktopAppConnectionLookup
        )
        var candidates: [DedupCandidate] = []
        for (url, var session) in sessionFiles {
            if let projectName = projectNames[session.sessionId] {
                session.desktopProjectName = projectName
            }
            session.lifecycle = SessionLifecyclePolicy.lifecycle(
                for: session, hostClass: session.hostClass, processAlive: processAlive(session),
                now: now, windows: lifecycleWindows,
                desktopAppRunning: desktopAppRunning(for: session, runningByBundleID: desktopAppRunningByBundleID)
            )
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            candidates.append(DedupCandidate(session: session, lifecycleRank: session.lifecycle.rawValue,
                                             mtime: mtime, path: url.path))
        }
        return candidates
    }

    nonisolated static func buildCandidates(
        _ jsonFiles: [URL],
        now: Date,
        desktopAppConnectionLookup: DesktopAppConnectionLookup = .live,
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup(),
        claudeDesktopSessions: any ClaudeDesktopSessionStateProviding = ClaudeDesktopSessionArchiveLookup(),
        processAlive: (Session) -> Bool = { $0.isAlive }
    ) -> [DedupCandidate] {
        let sessionFiles: [(url: URL, session: Session)] = jsonFiles.compactMap { url in
            guard let data = try? Data(contentsOf: url) else {
                sessionManagerLogger.warning("loadSessions: could not read \(url.lastPathComponent, privacy: .public)")
                return nil
            }
            guard let session = try? JSONDecoder.sessionDecoder.decode(Session.self, from: data) else {
                sessionManagerLogger.error("loadSessions: decode failed \(url.lastPathComponent, privacy: .public)")
                return nil
            }
            return (url, session)
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
            codexThreads: codexThreads,
            processAlive: processAlive
        )
    }

    nonisolated static func desktopProjectNamesBySessionID(
        in sessions: [Session],
        claudeMetadata: ClaudeDesktopSessionMetadataSnapshot?,
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup()
    ) -> [String: String] {
        var projectNames: [String: String] = [:]

        if let claudeMetadata {
            projectNames.merge(claudeMetadata.projectNamesBySessionID) { current, _ in current }
        }

        let codexDesktopThreadIDs = Set(sessions.filter(\.isCodexDesktopHost).map(\.sessionId))
        let codexThreadIDs = Self.codexThreadIDs(in: sessions)
        if let codexProjectNames = codexThreads.projectNames(matching: codexThreadIDs) {
            projectNames.merge(codexProjectNames.filter { codexDesktopThreadIDs.contains($0.key) }) { current, _ in current }
        }

        return projectNames
    }
}
