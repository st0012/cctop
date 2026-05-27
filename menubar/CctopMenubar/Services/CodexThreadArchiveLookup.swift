import Foundation
import SQLite3

struct CodexThreadArchiveLookup {
    let stateDatabasePath: String

    init(stateDatabasePath: String = Config.codexStateDatabasePath()) {
        self.stateDatabasePath = stateDatabasePath
    }

    func archivedThreadIDs(matching threadIDs: Set<String>) -> Set<String> {
        guard !threadIDs.isEmpty,
              FileManager.default.fileExists(atPath: stateDatabasePath) else {
            return []
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(stateDatabasePath, &database, flags, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 50)

        let sortedIDs = threadIDs.sorted()
        let placeholders = Array(repeating: "?", count: sortedIDs.count).joined(separator: ",")
        let sql = "SELECT id FROM threads WHERE archived = 1 AND id IN (\(placeholders))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        for (index, threadID) in sortedIDs.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), threadID, -1, sqliteTransient)
        }

        var archived: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            archived.insert(String(cString: text))
        }
        return archived
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
