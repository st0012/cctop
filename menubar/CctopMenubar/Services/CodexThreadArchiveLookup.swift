import Foundation
import SQLite3

struct CodexThreadArchiveLookup {
    let stateDatabasePath: String

    init(stateDatabasePath: String = Config.codexStateDatabasePath()) {
        self.stateDatabasePath = stateDatabasePath
    }

    /// Returns the subset of `threadIDs` that Codex has archived, or `nil` when the database
    /// exists but could not be read to completion (open/prepare/bind failure, or a busy/locked
    /// step). Callers that delete files must treat `nil` as "unknown — keep", never as "not
    /// archived". A missing database returns `[]` (no Codex state ⇒ nothing archived), not `nil`.
    func archivedThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        guard !threadIDs.isEmpty else { return [] }
        guard FileManager.default.fileExists(atPath: stateDatabasePath) else { return [] }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(stateDatabasePath, &database, flags, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 50)

        let sortedIDs = threadIDs.sorted()
        let placeholders = Array(repeating: "?", count: sortedIDs.count).joined(separator: ",")
        let sql = "SELECT id FROM threads WHERE archived = 1 AND id IN (\(placeholders))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        for (index, threadID) in sortedIDs.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), threadID, -1, sqliteTransient) == SQLITE_OK else {
                return nil
            }
        }

        var archived: Set<String> = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let text = sqlite3_column_text(statement, 0) {
                    archived.insert(String(cString: text))
                }
            case SQLITE_DONE:
                return archived
            default:
                return nil   // SQLITE_BUSY / SQLITE_ERROR / etc. — read did not complete
            }
        }
    }
}

struct ClaudeDesktopSessionArchiveLookup {
    let sessionsDirectory: String

    init(sessionsDirectory: String = Config.claudeCodeSessionsDir()) {
        self.sessionsDirectory = sessionsDirectory
    }

    /// Returns the subset of Claude Code `session_id`s whose Claude Desktop metadata is archived,
    /// or `nil` when a matching metadata read is uncertain. A missing metadata directory returns
    /// `[]` so machines without Claude Desktop keep the normal lifecycle behavior.
    func archivedSessionIDs(matching sessionIDs: Set<String>) -> Set<String>? {
        guard !sessionIDs.isEmpty else { return [] }

        let rootURL = URL(fileURLWithPath: sessionsDirectory)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                  at: rootURL,
                  includingPropertiesForKeys: [.contentModificationDateKey]
              ) else {
            return nil
        }

        var latestBySessionID: [String: ClaudeArchiveMatch] = [:]
        for case let url as URL in enumerator where isClaudeDesktopMetadataURL(url) {
            guard let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8) else {
                return nil
            }
            guard sessionIDs.contains(where: { content.contains($0) }) else { continue }
            guard let metadata = try? JSONDecoder().decode(ClaudeDesktopSessionMetadata.self, from: data) else {
                return nil
            }
            guard let cliSessionId = metadata.cliSessionId,
                  sessionIDs.contains(cliSessionId) else { continue }

            let match = ClaudeArchiveMatch(
                isArchived: metadata.isArchived == true,
                recencyKey: metadata.lastActivityAt ?? metadata.createdAt ?? "",
                path: url.path
            )
            if let current = latestBySessionID[cliSessionId],
               !match.isNewer(than: current) {
                continue
            }
            latestBySessionID[cliSessionId] = match
        }

        return Set(latestBySessionID.compactMap { sessionID, match in
            match.isArchived ? sessionID : nil
        })
    }

    private func isClaudeDesktopMetadataURL(_ url: URL) -> Bool {
        url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_")
    }
}

private struct ClaudeDesktopSessionMetadata: Decodable {
    let cliSessionId: String?
    let isArchived: Bool?
    let lastActivityAt: String?
    let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case cliSessionId
        case isArchived
        case lastActivityAt
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cliSessionId = try container.decodeIfPresent(String.self, forKey: .cliSessionId)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived)
        lastActivityAt = Self.decodeFlexibleRecencyKey(from: container, forKey: .lastActivityAt)
        createdAt = Self.decodeFlexibleRecencyKey(from: container, forKey: .createdAt)
    }

    private static func decodeFlexibleRecencyKey(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        if let string = try? container.decodeIfPresent(String.self, forKey: key) {
            return string
        }
        if let integer = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return String(integer)
        }
        if let double = try? container.decodeIfPresent(Double.self, forKey: key) {
            return String(double)
        }
        return nil
    }
}

private struct ClaudeArchiveMatch {
    let isArchived: Bool
    let recencyKey: String
    let path: String

    func isNewer(than other: ClaudeArchiveMatch) -> Bool {
        if recencyKey != other.recencyKey {
            return recencyKey > other.recencyKey
        }
        return path > other.path
    }
}

extension SessionManager {
    /// Batch snapshot for the display path. This never deletes files, so unreadable external state
    /// fails OPEN — at worst an archived session shows for one pass.
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

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
