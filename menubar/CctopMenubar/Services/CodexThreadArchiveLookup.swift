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

    /// Returns user-facing project names Codex records for threads. cctop uses this
    /// as display-only metadata for Desktop-hosted sessions, so lookup uncertainty
    /// returns `nil` and callers should preserve any existing label.
    func projectNames(matching threadIDs: Set<String>) -> [String: String]? {
        guard !threadIDs.isEmpty else { return [:] }
        guard FileManager.default.fileExists(atPath: stateDatabasePath) else { return [:] }

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
        let sql = """
        SELECT id, git_origin_url, cwd
        FROM threads
        WHERE id IN (\(placeholders))
          AND (
              (git_origin_url IS NOT NULL AND git_origin_url != '')
              OR (cwd IS NOT NULL AND cwd != '')
          )
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard Self.bind(sortedIDs, to: statement) else { return nil }

        var names: [String: String] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let idText = sqlite3_column_text(statement, 0) else {
                    continue
                }
                let threadID = String(cString: idText)
                let origin = Self.columnString(statement, 1)
                let cwd = Self.columnString(statement, 2)
                if let name = origin.flatMap({ Self.projectName(fromGitOriginURL: $0) })
                    ?? cwd.flatMap({ Self.projectName(fromPath: $0) }) {
                    names[threadID] = name
                }
            case SQLITE_DONE:
                return names
            default:
                return nil
            }
        }
    }

    /// Returns Codex Desktop-owned one-shot exec helper threads. `source = 'exec'`
    /// alone also covers user-run `codex exec`, so verify the rollout originator before hiding.
    func execHelperThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
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
        let sql = """
        SELECT id, rollout_path
        FROM threads
        WHERE source = 'exec'
          AND has_user_event = 0
          AND id IN (\(placeholders))
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard Self.bind(sortedIDs, to: statement) else { return nil }

        var helpers: Set<String> = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let idText = sqlite3_column_text(statement, 0) else { continue }
                let threadID = String(cString: idText)
                guard let rolloutPath = Self.columnString(statement, 1),
                      Self.rolloutOriginator(at: rolloutPath) == "Codex Desktop" else {
                    continue
                }
                helpers.insert(threadID)
            case SQLITE_DONE:
                return helpers
            default:
                return nil
            }
        }
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

        guard Self.bind(sortedIDs, to: statement) else { return nil }

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

    private static func projectName(fromGitOriginURL origin: String) -> String? {
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withoutTrailingSlash = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lastComponent: String
        if let slash = withoutTrailingSlash.lastIndex(of: "/") {
            lastComponent = String(withoutTrailingSlash[withoutTrailingSlash.index(after: slash)...])
        } else if let colon = withoutTrailingSlash.lastIndex(of: ":") {
            lastComponent = String(withoutTrailingSlash[withoutTrailingSlash.index(after: colon)...])
        } else {
            lastComponent = withoutTrailingSlash
        }

        let name = lastComponent.hasSuffix(".git") ? String(lastComponent.dropLast(4)) : lastComponent
        return name.isEmpty ? nil : name
    }

    private static func projectName(fromPath path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else { return nil }
        let name = (normalized as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func rolloutOriginator(at path: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }

        var buffered = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 8_192) else {
                return nil
            }
            guard !chunk.isEmpty else {
                return sessionMetaOriginator(from: buffered)
            }

            buffered.append(chunk)
            while let newline = buffered.firstIndex(of: 0x0a) {
                let line = buffered[..<newline]
                buffered.removeSubrange(...newline)
                if let originator = sessionMetaOriginator(from: Data(line)) {
                    return originator
                }
            }
        }
    }

    private static func sessionMetaOriginator(from data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }
        return payload["originator"] as? String
    }

    private static func columnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        let value = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func bind(_ threadIDs: [String], to statement: OpaquePointer) -> Bool {
        for (index, threadID) in threadIDs.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), threadID, -1, sqliteTransient) == SQLITE_OK else {
                return false
            }
        }
        return true
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
