import AppKit
import Foundation

struct DesktopAppConnectionLookup {
    let isRunning: (String) -> Bool

    init(_ isRunning: @escaping (String) -> Bool) {
        self.isRunning = isRunning
    }

    static let live = DesktopAppConnectionLookup { bundleID in
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
}

struct SessionVisibilitySnapshot {
    let archivedCodexThreadIDs: Set<String>
    let codexSubagentThreadIDs: Set<String>
    let codexExecHelperThreadIDs: Set<String>
    let archivedClaudeSessionIDs: Set<String>
    let codexSubagentCandidates: [DedupCandidate]
    let liveCandidates: [DedupCandidate]
}

extension SessionManager {
    nonisolated static func visibilitySnapshot(in candidates: [DedupCandidate]) -> SessionVisibilitySnapshot {
        let sessions = candidates.map(\.session)
        let claudeMetadata = claudeDesktopMetadataSnapshot(in: sessions)
        return visibilitySnapshot(in: candidates, sessions: sessions, claudeMetadata: claudeMetadata)
    }

    nonisolated static func visibilitySnapshot(
        in candidates: [DedupCandidate],
        claudeMetadata: ClaudeDesktopSessionMetadataSnapshot?
    ) -> SessionVisibilitySnapshot {
        visibilitySnapshot(in: candidates, sessions: candidates.map(\.session), claudeMetadata: claudeMetadata)
    }

    private nonisolated static func visibilitySnapshot(
        in candidates: [DedupCandidate],
        sessions: [Session],
        claudeMetadata: ClaudeDesktopSessionMetadataSnapshot?
    ) -> SessionVisibilitySnapshot {
        let archivedCodexThreadIDs = archivedCodexDesktopThreadIDs(in: sessions)
        let codexSubagentThreadIDs = codexSubagentThreadIDs(in: sessions)
        let codexExecHelperThreadIDs = codexExecHelperThreadIDs(in: sessions)
        let archivedClaudeSessionIDs = claudeMetadata?.archivedSessionIDs ?? []
        let codexSubagentCandidates = candidates.filter {
            isCodexSubagentSession($0.session, subagentThreadIDs: codexSubagentThreadIDs)
        }
        let liveCandidates = candidates.filter {
            !isArchivedCodexDesktopSession($0.session, archivedThreadIDs: archivedCodexThreadIDs)
                && !isCodexSubagentSession($0.session, subagentThreadIDs: codexSubagentThreadIDs)
                && !isCodexExecHelperSession($0.session, execHelperThreadIDs: codexExecHelperThreadIDs)
                && !isArchivedClaudeDesktopSession($0.session, archivedSessionIDs: archivedClaudeSessionIDs)
                && !isOrphanedEndedClaudeDesktopSession($0.session, metadataSnapshot: claudeMetadata)
        }
        return SessionVisibilitySnapshot(
            archivedCodexThreadIDs: archivedCodexThreadIDs,
            codexSubagentThreadIDs: codexSubagentThreadIDs,
            codexExecHelperThreadIDs: codexExecHelperThreadIDs,
            archivedClaudeSessionIDs: archivedClaudeSessionIDs,
            codexSubagentCandidates: codexSubagentCandidates,
            liveCandidates: liveCandidates
        )
    }

    /// Batch snapshot for the display path. This never deletes files, so unreadable external state
    /// fails OPEN: at worst an archived session shows for one pass.
    nonisolated static func archivedCodexDesktopThreadIDs(in sessions: [Session]) -> Set<String> {
        let threadIDs = Set(
            sessions
                .filter(\.isCodexDesktopHost)
                .map(\.sessionId)
        )
        return CodexThreadArchiveLookup().archivedThreadIDs(matching: threadIDs) ?? []
    }

    nonisolated static func isArchivedCodexDesktopSession(
        _ session: Session,
        archivedThreadIDs: Set<String>
    ) -> Bool {
        session.isCodexDesktopHost && archivedThreadIDs.contains(session.sessionId)
    }

    /// Codex records whether a thread is user-owned or subagent-owned in its local thread
    /// database. That signal applies across Codex hosts: Desktop and terminal Codex CLI.
    nonisolated static func codexSubagentThreadIDs(in sessions: [Session]) -> Set<String> {
        let threadIDs = Set(
            sessions
                .filter { $0.isCodex || $0.isCodexDesktopHost }
                .map(\.sessionId)
        )
        return CodexThreadArchiveLookup().subagentThreadIDs(matching: threadIDs) ?? []
    }

    nonisolated static func isCodexSubagentSession(
        _ session: Session,
        subagentThreadIDs: Set<String>
    ) -> Bool {
        (session.isCodex || session.isCodexDesktopHost) && subagentThreadIDs.contains(session.sessionId)
    }

    /// Codex Desktop can launch short-lived `codex exec` helper threads. They are useful as
    /// rollout artifacts but should not appear as user-visible cctop sessions.
    nonisolated static func codexExecHelperThreadIDs(in sessions: [Session]) -> Set<String> {
        let threadIDs = Set(
            sessions
                .filter { $0.isCodex || $0.isCodexDesktopHost }
                .map(\.sessionId)
        )
        return CodexThreadArchiveLookup().execHelperThreadIDs(matching: threadIDs) ?? []
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
    nonisolated static func codexSubagentHiddenSessionSnapshot(path: String) throws -> Session? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var latest = try Session.fromFile(path: path)
        guard !latest.hidden, latest.isCodex || latest.isCodexDesktopHost else { return nil }
        guard let subagentIDs = CodexThreadArchiveLookup().subagentThreadIDs(matching: [latest.sessionId]),
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
                    guard let hiddenSession = try Self.codexSubagentHiddenSessionSnapshot(path: candidate.path) else {
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

    /// Batch snapshot for the display path. This mirrors the Codex behavior: archive metadata read
    /// uncertainty fails OPEN because this path never deletes files.
    nonisolated static func archivedClaudeDesktopSessionIDs(in sessions: [Session]) -> Set<String> {
        claudeDesktopMetadataSnapshot(in: sessions)?.archivedSessionIDs ?? []
    }

    nonisolated static func claudeDesktopMetadataSnapshot(in sessions: [Session]) -> ClaudeDesktopSessionMetadataSnapshot? {
        let sessionIDs = Set(
            sessions
                .filter(\.isClaudeDesktopHost)
                .map(\.sessionId)
        )
        return ClaudeDesktopSessionArchiveLookup().metadataSnapshot(matching: sessionIDs)
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
    /// `loadSessions` uses, this re-reads Codex's SQLite state at call time, so a thread archived
    /// after the GC directory scan is never deleted out from under a pending unarchive. When the
    /// database exists but cannot be read, the lookup returns nil and we fail SAFE.
    nonisolated static func isCodexDesktopThreadArchived(_ session: Session) -> Bool {
        guard session.isCodexDesktopHost else { return false }
        guard let archived = CodexThreadArchiveLookup().archivedThreadIDs(matching: [session.sessionId]) else {
            return true
        }
        return archived.contains(session.sessionId)
    }

    /// Fresh single-session archive check for Claude Desktop's GC deletion decision. Missing
    /// metadata means "not archived"; unreadable matching metadata means "unknown" and keeps the
    /// file.
    nonisolated static func isClaudeDesktopSessionArchived(_ session: Session) -> Bool {
        guard session.isClaudeDesktopHost else { return false }
        guard let archived = ClaudeDesktopSessionArchiveLookup().archivedSessionIDs(matching: [session.sessionId]) else {
            return true
        }
        return archived.contains(session.sessionId)
    }

    nonisolated static func isArchivedDesktopSession(_ session: Session) -> Bool {
        isCodexDesktopThreadArchived(session) || isClaudeDesktopSessionArchived(session)
    }

    /// Decode each session file, derive its lifecycle, and capture mtime — the inputs the dedup
    /// comparator needs. Pure (no published state), kept off the main class body.
    nonisolated static func buildCandidates(
        _ sessionFiles: [(url: URL, session: Session)],
        now: Date,
        desktopAppConnectionLookup: DesktopAppConnectionLookup = .live,
        claudeMetadata: ClaudeDesktopSessionMetadataSnapshot?
    ) -> [DedupCandidate] {
        let projectNames = desktopProjectNamesBySessionID(
            in: sessionFiles.map(\.session),
            claudeMetadata: claudeMetadata
        )
        var candidates: [DedupCandidate] = []
        for (url, var session) in sessionFiles {
            if let projectName = projectNames[session.sessionId] {
                session.desktopProjectName = projectName
            }
            session.lifecycle = SessionLifecyclePolicy.lifecycle(
                for: session, hostClass: session.hostClass, processAlive: session.isAlive,
                now: now, windows: lifecycleWindows,
                desktopAppRunning: desktopAppRunning(for: session, lookup: desktopAppConnectionLookup)
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
        desktopAppConnectionLookup: DesktopAppConnectionLookup = .live
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

        let claudeMetadata = claudeDesktopMetadataSnapshot(in: sessionFiles.map(\.session))
        return buildCandidates(
            sessionFiles,
            now: now,
            desktopAppConnectionLookup: desktopAppConnectionLookup,
            claudeMetadata: claudeMetadata
        )
    }

    nonisolated static func desktopProjectNamesBySessionID(in sessions: [Session]) -> [String: String] {
        let claudeSessionIDs = Set(sessions.filter(\.isClaudeDesktopHost).map(\.sessionId))
        let claudeMetadata = ClaudeDesktopSessionArchiveLookup().metadataSnapshot(matching: claudeSessionIDs)
        return desktopProjectNamesBySessionID(in: sessions, claudeMetadata: claudeMetadata)
    }

    nonisolated static func desktopProjectNamesBySessionID(
        in sessions: [Session],
        claudeMetadata: ClaudeDesktopSessionMetadataSnapshot?
    ) -> [String: String] {
        var projectNames: [String: String] = [:]

        if let claudeMetadata {
            projectNames.merge(claudeMetadata.projectNamesBySessionID) { current, _ in current }
        }

        let codexThreadIDs = Set(sessions.filter(\.isCodexDesktopHost).map(\.sessionId))
        if let codexProjectNames = CodexThreadArchiveLookup().projectNames(matching: codexThreadIDs) {
            projectNames.merge(codexProjectNames) { current, _ in current }
        }

        return projectNames
    }
}
