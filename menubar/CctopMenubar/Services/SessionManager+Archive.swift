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

struct SessionVisibilitySnapshot {
    let archivedCodexThreadIDs: Set<String>
    let missingCodexDesktopThreadIDs: Set<String>
    let codexSubagentThreadIDs: Set<String>
    let codexExecHelperThreadIDs: Set<String>
    let archivedClaudeSessionIDs: Set<String>
    let codexSubagentCandidates: [DedupCandidate]
    let liveCandidates: [DedupCandidate]
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

    nonisolated static func visibilitySnapshot(
        in candidates: [DedupCandidate],
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup(),
        claudeDesktopSessions: any ClaudeDesktopSessionStateProviding = ClaudeDesktopSessionArchiveLookup(),
        now: Date = Date()
    ) -> SessionVisibilitySnapshot {
        let sessions = candidates.map(\.session)
        let claudeMetadata = claudeDesktopMetadataSnapshot(in: sessions, claudeDesktopSessions: claudeDesktopSessions)
        return visibilitySnapshot(in: candidates, sessions: sessions, claudeMetadata: claudeMetadata, codexThreads: codexThreads, now: now)
    }

    nonisolated static func visibilitySnapshot(
        in candidates: [DedupCandidate],
        claudeMetadata: ClaudeDesktopSessionMetadataSnapshot?,
        codexThreads: any CodexThreadStateProviding = CodexThreadArchiveLookup(),
        now: Date = Date()
    ) -> SessionVisibilitySnapshot {
        visibilitySnapshot(
            in: candidates,
            sessions: candidates.map(\.session),
            claudeMetadata: claudeMetadata,
            codexThreads: codexThreads,
            now: now
        )
    }

    private nonisolated static func visibilitySnapshot(
        in candidates: [DedupCandidate],
        sessions: [Session],
        claudeMetadata: ClaudeDesktopSessionMetadataSnapshot?,
        codexThreads: any CodexThreadStateProviding,
        now: Date
    ) -> SessionVisibilitySnapshot {
        let archivedCodexThreadIDs = archivedCodexDesktopThreadIDs(in: sessions, codexThreads: codexThreads)
        let missingCodexDesktopThreadIDs = missingCodexDesktopThreadIDs(in: sessions, codexThreads: codexThreads, now: now)
        let codexSubagentThreadIDs = codexSubagentThreadIDs(in: sessions, codexThreads: codexThreads)
        let codexExecHelperThreadIDs = codexExecHelperThreadIDs(in: sessions, codexThreads: codexThreads)
        let archivedClaudeSessionIDs = claudeMetadata?.archivedSessionIDs ?? []
        let codexSubagentCandidates = candidates.filter {
            isCodexSubagentSession($0.session, subagentThreadIDs: codexSubagentThreadIDs)
        }
        let liveCandidates = candidates.filter {
            !isArchivedCodexDesktopSession($0.session, archivedThreadIDs: archivedCodexThreadIDs)
                && !isMissingCodexDesktopSession($0.session, missingThreadIDs: missingCodexDesktopThreadIDs)
                && !isCodexSubagentSession($0.session, subagentThreadIDs: codexSubagentThreadIDs)
                && !isCodexExecHelperSession($0.session, execHelperThreadIDs: codexExecHelperThreadIDs)
                && !isArchivedClaudeDesktopSession($0.session, archivedSessionIDs: archivedClaudeSessionIDs)
                && !isOrphanedEndedClaudeDesktopSession($0.session, metadataSnapshot: claudeMetadata)
        }
        return SessionVisibilitySnapshot(
            archivedCodexThreadIDs: archivedCodexThreadIDs,
            missingCodexDesktopThreadIDs: missingCodexDesktopThreadIDs,
            codexSubagentThreadIDs: codexSubagentThreadIDs,
            codexExecHelperThreadIDs: codexExecHelperThreadIDs,
            archivedClaudeSessionIDs: archivedClaudeSessionIDs,
            codexSubagentCandidates: codexSubagentCandidates,
            liveCandidates: liveCandidates
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
