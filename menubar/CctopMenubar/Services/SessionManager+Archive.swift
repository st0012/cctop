// swiftlint:disable file_length
import Foundation

/// The external inputs SessionManager consults while deriving session state: the sessions
/// directory, the Codex/Claude Desktop archive stores, desktop-app liveness, process liveness,
/// the notification preference, and the clock. Production uses `.live()`; tests override
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
    let codexSubagentThreadIDs: Set<String>
    let codexExecHelperThreadIDs: Set<String>
    let archivedClaudeSessionIDs: Set<String>
}

enum SessionHiddenReason: Equatable {
    case persistedHidden
    case autoHidden
    case archivedCodexDesktop
    case missingCodexDesktopThread
    case codexSubagent
    case codexExecHelper
    case archivedClaudeDesktop
    case orphanedEndedClaudeDesktop
    case claudeDesktopStartupPlaceholder

    /// Hidden helper/subagent records still represent live ownership of the path, so they
    /// protect cleanup. Archived/deleted desktop records are hidden UI state instead; only
    /// explicitly emitted cleanup sources can make those paths cleanup candidates.
    var protectsCleanupPath: Bool {
        switch self {
        case .persistedHidden, .autoHidden, .codexSubagent, .codexExecHelper:
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

    var codexSubagentCandidates: [DedupCandidate] {
        records.compactMap { record in
            guard case .hidden(.codexSubagent) = record.disposition else { return nil }
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

    /// Cleanup sources are only emitted from cctop JSON records classified in this pass.
    /// External host metadata may hide or enrich those records, but it never creates cleanup rows
    /// without a session file because the scanner needs cctop's project path and recency context.
    /// Missing/deleted desktop conversations stay hidden and preserved, but do not become cleanup
    /// sources unless the host metadata explicitly marks the conversation archived.
    var cleanupSources: [SessionCleanupSource] {
        records.compactMap { record in
            guard case .hidden(let reason) = record.disposition,
                  Self.emitsCleanupSource(for: reason),
                  Self.hasKnownCleanupPath(record.candidate.session.projectPath) else {
                return nil
            }
            return SessionCleanupSource(session: record.candidate.session)
        }
    }

    private static func hasKnownCleanupPath(_ path: String) -> Bool {
        !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && path != "/"
    }

    private static func emitsCleanupSource(for reason: SessionHiddenReason) -> Bool {
        reason == .archivedCodexDesktop || reason == .archivedClaudeDesktop
    }

    var archivedCodexThreadIDs: Set<String> { evidence.archivedCodexThreadIDs }
    var missingCodexDesktopThreadIDs: Set<String> { evidence.missingCodexDesktopThreadIDs }
    var codexSubagentThreadIDs: Set<String> { evidence.codexSubagentThreadIDs }
    var codexExecHelperThreadIDs: Set<String> { evidence.codexExecHelperThreadIDs }
    var archivedClaudeSessionIDs: Set<String> { evidence.archivedClaudeSessionIDs }
}

extension SessionManager {
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
        let archivedCodexThreadIDs = archivedCodexDesktopThreadIDs(in: externallyClassifiableSessions, codexThreads: codexThreads)
        let missingCodexDesktopThreadIDs = missingCodexDesktopThreadIDs(
            in: externallyClassifiableSessions,
            codexThreads: codexThreads,
            now: now
        )
        let codexSubagentThreadIDs = codexSubagentThreadIDs(in: externallyClassifiableSessions, codexThreads: codexThreads)
        let codexExecHelperThreadIDs = codexExecHelperThreadIDs(in: externallyClassifiableSessions, codexThreads: codexThreads)
        let archivedClaudeSessionIDs = claudeMetadata?.archivedSessionIDs ?? []

        let evidence = SessionClassificationEvidence(
            archivedCodexThreadIDs: archivedCodexThreadIDs,
            missingCodexDesktopThreadIDs: missingCodexDesktopThreadIDs,
            codexSubagentThreadIDs: codexSubagentThreadIDs,
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
        if isCodexSubagentSession(session, subagentThreadIDs: evidence.codexSubagentThreadIDs) {
            return .hidden(.codexSubagent)
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
        let classifiableSessions = decoded
            .map(\.session)
            .filter { !$0.hidden && !$0.shouldAutoHide }
        let claudeMetadata = Self.claudeDesktopMetadataSnapshot(
            in: classifiableSessions,
            claudeDesktopSessions: dataSources.claudeDesktopSessions
        )
        let candidates = Self.buildCandidates(
            decoded,
            now: now,
            desktopAppConnectionLookup: dataSources.desktopAppConnection,
            claudeMetadata: claudeMetadata,
            codexThreads: dataSources.codexThreads,
            processAlive: dataSources.processAlive
        )
        return Self.sessionClassificationSnapshot(
            in: candidates,
            sessions: decoded.map(\.session),
            claudeMetadata: claudeMetadata,
            codexThreads: dataSources.codexThreads,
            now: now
        )
    }

    /// Batch snapshot for the display path. This never deletes files, so unreadable external state
    /// fails OPEN: at worst an archived session shows for one pass.
    nonisolated static func archivedCodexDesktopThreadIDs(
        in sessions: [Session],
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup()
    ) -> Set<String> {
        let threadIDs = Set(
            sessions
                .filter(\.isCodexDesktopHost)
                .map(\.sessionId)
        )
        return codexThreads.archivedThreadIDs(matching: threadIDs) ?? []
    }

    nonisolated static func isArchivedCodexDesktopSession(
        _ session: Session,
        archivedThreadIDs: Set<String>
    ) -> Bool {
        session.isCodexDesktopHost && archivedThreadIDs.contains(session.sessionId)
    }

    /// Codex Desktop sessions should correspond to a Codex thread row. If the thread store is
    /// readable and the row is gone, the app should not publish the stale hook session.
    nonisolated static func missingCodexDesktopThreadIDs(
        in sessions: [Session],
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup(),
        now: Date = Date()
    ) -> Set<String> {
        let codexDesktopSessions = sessions.filter { $0.source == Session.codexSource && $0.isCodexDesktopHost }
        let threadIDs = Set(codexDesktopSessions.map(\.sessionId))
        guard let existingThreadIDs = codexThreads.existingThreadIDs(matching: threadIDs) else { return [] }
        let missingThreadIDs = threadIDs.subtracting(existingThreadIDs)
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

    /// Codex records whether a thread is user-owned or subagent-owned in its local thread
    /// database. That signal applies across Codex hosts: Desktop and terminal Codex CLI.
    nonisolated static func codexSubagentThreadIDs(
        in sessions: [Session],
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup()
    ) -> Set<String> {
        let threadIDs = Set(
            sessions
                .filter { $0.isCodex || $0.isCodexDesktopHost }
                .map(\.sessionId)
        )
        return codexThreads.subagentThreadIDs(matching: threadIDs) ?? []
    }

    nonisolated static func isCodexSubagentSession(
        _ session: Session,
        subagentThreadIDs: Set<String>
    ) -> Bool {
        (session.isCodex || session.isCodexDesktopHost) && subagentThreadIDs.contains(session.sessionId)
    }

    /// Codex Desktop can launch short-lived `codex exec` helper threads. They are useful as
    /// rollout artifacts but should not appear as user-visible cctop sessions.
    nonisolated static func codexExecHelperThreadIDs(
        in sessions: [Session],
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup()
    ) -> Set<String> {
        let threadIDs = Set(
            sessions
                .filter { $0.isCodex || $0.isCodexDesktopHost }
                .map(\.sessionId)
        )
        return codexThreads.execHelperThreadIDs(matching: threadIDs) ?? []
    }

    nonisolated static func isCodexExecHelperSession(
        _ session: Session,
        execHelperThreadIDs: Set<String>
    ) -> Bool {
        (session.isCodex || session.isCodexDesktopHost) && execHelperThreadIDs.contains(session.sessionId)
    }

    /// Fresh single-session check used before persisting a hidden flag for a Codex subagent
    /// thread. Lookup uncertainty fails OPEN: if we cannot prove it is a subagent, leave it
    /// visible rather than permanently hiding the file.
    nonisolated static func codexSubagentHiddenSessionSnapshot(
        path: String,
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup()
    ) throws -> Session? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var latest = try Session.fromFile(path: path)
        guard !latest.hidden, latest.isCodex || latest.isCodexDesktopHost else { return nil }
        guard let subagentIDs = codexThreads.subagentThreadIDs(matching: [latest.sessionId]),
              subagentIDs.contains(latest.sessionId) else {
            return nil
        }
        latest.isSubagentSession = true
        latest.hidden = true
        return latest
    }

    nonisolated static func autoHiddenSessionSnapshot(path: String) throws -> Session? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var latest = try Session.fromFile(path: path)
        guard !latest.hidden, latest.shouldAutoHide else { return nil }
        latest.hidden = true
        return latest
    }

    func hideCodexSubagentSessions(_ candidates: [DedupCandidate]) {
        for candidate in candidates {
            sessionManagerLogger.info(
                "hiding Codex subagent session \(candidate.session.sessionId, privacy: .public)"
            )
            do {
                try withSessionLock(sessionPath: candidate.path) {
                    guard let hiddenSession = try Self.codexSubagentHiddenSessionSnapshot(
                        path: candidate.path,
                        codexThreads: dataSources.codexThreads
                    ) else {
                        return
                    }
                    try hiddenSession.writeToFile(path: candidate.path)
                }
            } catch {
                let sessionId = candidate.session.sessionId
                sessionManagerLogger.warning(
                    "skipping Codex subagent hide for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
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

        let codexThreadIDs = Set(sessions.filter(\.isCodexDesktopHost).map(\.sessionId))
        if let codexProjectNames = codexThreads.projectNames(matching: codexThreadIDs) {
            projectNames.merge(codexProjectNames) { current, _ in current }
        }

        return projectNames
    }
}
