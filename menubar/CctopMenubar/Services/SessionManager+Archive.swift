import Foundation

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
        let sessionIDs = Set(
            sessions
                .filter(\.isClaudeDesktopHost)
                .map(\.sessionId)
        )
        return ClaudeDesktopSessionArchiveLookup().archivedSessionIDs(matching: sessionIDs) ?? []
    }

    nonisolated static func isArchivedClaudeDesktopSession(
        _ session: Session,
        archivedSessionIDs: Set<String>
    ) -> Bool {
        session.isClaudeDesktopHost && archivedSessionIDs.contains(session.sessionId)
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
}
