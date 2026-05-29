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

extension SessionManager {
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
        _ jsonFiles: [URL],
        now: Date,
        desktopAppConnectionLookup: DesktopAppConnectionLookup = .live
    ) -> [DedupCandidate] {
        var candidates: [DedupCandidate] = []
        for url in jsonFiles {
            guard let data = try? Data(contentsOf: url) else {
                sessionManagerLogger.warning("loadSessions: could not read \(url.lastPathComponent, privacy: .public)")
                continue
            }
            guard var session = try? JSONDecoder.sessionDecoder.decode(Session.self, from: data) else {
                sessionManagerLogger.error("loadSessions: decode failed \(url.lastPathComponent, privacy: .public)")
                continue
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
}
