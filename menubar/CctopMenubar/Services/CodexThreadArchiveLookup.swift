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
        matchingThreadIDs(matching: threadIDs, whereClause: "archived = 1")
    }

    /// Returns the subset of `threadIDs` Codex marks as subagent-owned. This is display-only
    /// metadata, so callers should fail OPEN when the lookup returns `nil`.
    func subagentThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        matchingThreadIDs(matching: threadIDs, whereClause: "thread_source = 'subagent'")
    }

    private func matchingThreadIDs(matching threadIDs: Set<String>, whereClause predicate: String) -> Set<String>? {
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
        let sql = "SELECT id FROM threads WHERE \(predicate) AND id IN (\(placeholders))"
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

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
