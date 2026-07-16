import SQLite3

extension CodexThreadArchiveLookup {
    static func threadSnapshotSQL(in database: OpaquePointer, matchingCount: Int) -> String? {
        guard let columns = tableColumns("threads", in: database),
              columns.contains("id") else {
            return nil
        }

        let edgeColumns = tableColumns("thread_spawn_edges", in: database) ?? []
        let hasSpawnEdges = edgeColumns.contains("child_thread_id") && edgeColumns.contains("parent_thread_id")

        let selections = [
            "threads.id",
            selectThreadColumn("archived", from: columns, defaultingTo: "0"),
            selectThreadColumn("source", from: columns, defaultingTo: "NULL"),
            selectThreadColumn("has_user_event", from: columns, defaultingTo: "0"),
            selectThreadColumn("rollout_path", from: columns, defaultingTo: "NULL"),
            selectThreadColumn("git_origin_url", from: columns, defaultingTo: "NULL"),
            selectThreadColumn("cwd", from: columns, defaultingTo: "NULL"),
            hasSpawnEdges ? "spawn_edges.parent_thread_id" : "NULL AS spawn_parent_thread_id",
            hasSpawnEdges ? "1 AS spawn_edges_available" : "0 AS spawn_edges_available",
        ]
        let placeholders = Array(repeating: "?", count: matchingCount).joined(separator: ",")
        let from = hasSpawnEdges
            ? "threads LEFT JOIN thread_spawn_edges AS spawn_edges ON spawn_edges.child_thread_id = threads.id"
            : "threads"
        return "SELECT \(selections.joined(separator: ", ")) FROM \(from) WHERE threads.id IN (\(placeholders))"
    }

    private static func tableColumns(_ table: String, in database: OpaquePointer) -> Set<String>? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let nameText = sqlite3_column_text(statement, 1) {
                    columns.insert(String(cString: nameText))
                }
            case SQLITE_DONE:
                return columns
            default:
                return nil
            }
        }
    }

    private static func selectThreadColumn(_ name: String, from columns: Set<String>, defaultingTo fallback: String) -> String {
        columns.contains(name) ? "threads.\(name)" : "\(fallback) AS \(name)"
    }

    static func bind(_ threadIDs: [String], to statement: OpaquePointer) -> Bool {
        for (index, threadID) in threadIDs.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), threadID, -1, sqliteTransient) == SQLITE_OK else {
                return false
            }
        }
        return true
    }
}
