import Darwin
import Foundation
import SQLite3

/// Read-side seam over Codex's local thread state. `CodexThreadArchiveLookup` is the live
/// SQLite-backed implementation; tests substitute in-memory stubs so visibility and archive
/// logic can run without a database on disk. `nil` means the lookup could not prove an answer,
/// either because the store was unreadable or because absence is intentionally treated as unknown.
protocol CodexThreadStateProviding {
    func existingThreadIDs(matching threadIDs: Set<String>) -> Set<String>?
    func archivedThreadIDs(matching threadIDs: Set<String>) -> Set<String>?
    func subagentThreadIDs(matching threadIDs: Set<String>) -> Set<String>?
    func execHelperThreadIDs(matching threadIDs: Set<String>) -> Set<String>?
    func projectNames(matching threadIDs: Set<String>) -> [String: String]?
}

final class CodexThreadArchiveLookup {
    let stateDatabasePath: String
    private let cacheLock = NSLock()
    private var indexCache: CodexThreadStateIndexCache?

    init(stateDatabasePath: String = Config.codexStateDatabasePath()) {
        self.stateDatabasePath = stateDatabasePath
    }

    /// Returns the subset of `threadIDs` present in Codex's thread state. Unlike archive
    /// lookups, a missing database is unknown rather than proof of absence, so callers
    /// should fail OPEN when this returns `nil`.
    func existingThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        guard !threadIDs.isEmpty else { return [] }
        guard let snapshot = stateSnapshot() else { return nil }
        switch snapshot {
        case .missing:
            return nil
        case .available(let index):
            return index.existingThreadIDs.intersection(threadIDs)
        }
    }

    /// Returns the subset of `threadIDs` that Codex has archived, or `nil` when the database
    /// exists but could not be read to completion (open/prepare/bind failure, or a busy/locked
    /// step). Callers that delete files must treat `nil` as "unknown — keep", never as "not
    /// archived". A missing database returns `[]` (no Codex state ⇒ nothing archived), not `nil`.
    func archivedThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        guard !threadIDs.isEmpty else { return [] }
        guard let snapshot = stateSnapshot() else { return nil }
        switch snapshot {
        case .missing:
            return []
        case .available(let index):
            return index.archivedThreadIDs.intersection(threadIDs)
        }
    }

    /// Returns the subset of `threadIDs` Codex marks as subagent-owned. This is display-only
    /// metadata, so callers should fail OPEN when the lookup returns `nil`.
    func subagentThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        guard !threadIDs.isEmpty else { return [] }
        guard let snapshot = stateSnapshot() else { return nil }
        switch snapshot {
        case .missing:
            return []
        case .available(let index):
            return index.subagentThreadIDs.intersection(threadIDs)
        }
    }

    /// Returns user-facing project names Codex records for threads. cctop uses this
    /// as display-only metadata for Desktop-hosted sessions, so lookup uncertainty
    /// returns `nil` and callers should preserve any existing label.
    func projectNames(matching threadIDs: Set<String>) -> [String: String]? {
        guard !threadIDs.isEmpty else { return [:] }
        guard let snapshot = stateSnapshot() else { return nil }
        switch snapshot {
        case .missing:
            return [:]
        case .available(let index):
            return index.projectNamesByThreadID.filter { threadIDs.contains($0.key) }
        }
    }

    /// Returns Codex Desktop-owned one-shot exec helper threads. `source = 'exec'`
    /// alone also covers user-run `codex exec`, so verify the rollout originator before hiding.
    func execHelperThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        guard !threadIDs.isEmpty else { return [] }
        guard let snapshot = stateSnapshot() else { return nil }
        switch snapshot {
        case .missing:
            return []
        case .available(let index):
            return index.execHelperThreadIDs.intersection(threadIDs)
        }
    }

    private func stateSnapshot() -> CodexThreadStateSnapshot? {
        guard let fingerprint = Self.databaseFingerprint(at: stateDatabasePath) else {
            return nil
        }

        cacheLock.lock()
        if let indexCache, indexCache.fingerprint == fingerprint {
            let snapshot = indexCache.snapshot
            cacheLock.unlock()
            return snapshot
        }
        cacheLock.unlock()

        guard let snapshot = loadStateSnapshot(for: fingerprint) else {
            return nil
        }

        cacheLock.lock()
        indexCache = CodexThreadStateIndexCache(fingerprint: fingerprint, snapshot: snapshot)
        cacheLock.unlock()
        return snapshot
    }

    private func loadStateSnapshot(for fingerprint: CodexThreadStateDatabaseFingerprint) -> CodexThreadStateSnapshot? {
        guard fingerprint != .missing else {
            return .missing
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(stateDatabasePath, &database, flags, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 50)

        let sql = """
        SELECT id, archived, thread_source, source, has_user_event, rollout_path, git_origin_url, cwd
        FROM threads
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var index = CodexThreadStateIndex()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                Self.addCurrentRow(statement, to: &index)
            case SQLITE_DONE:
                return .available(index)
            default:
                return nil   // SQLITE_BUSY / SQLITE_ERROR / etc. — read did not complete
            }
        }
    }

    private static func databaseFingerprint(at path: String) -> CodexThreadStateDatabaseFingerprint? {
        var statInfo = stat()
        guard path.withCString({ lstat($0, &statInfo) }) == 0 else {
            return errno == ENOENT ? .missing : nil
        }
        return .file(
            database: fileFingerprint(from: statInfo),
            wal: optionalFileFingerprint(at: path + "-wal"),
            shm: optionalFileFingerprint(at: path + "-shm")
        )
    }

    private static func optionalFileFingerprint(at path: String) -> CodexThreadStateFileFingerprint? {
        var statInfo = stat()
        guard path.withCString({ lstat($0, &statInfo) }) == 0 else { return nil }
        return fileFingerprint(from: statInfo)
    }

    private static func fileFingerprint(from statInfo: stat) -> CodexThreadStateFileFingerprint {
        CodexThreadStateFileFingerprint(
            modifiedSeconds: Int64(statInfo.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(statInfo.st_mtimespec.tv_nsec),
            fileSize: Int64(statInfo.st_size)
        )
    }

    private static func addCurrentRow(_ statement: OpaquePointer, to index: inout CodexThreadStateIndex) {
        guard let idText = sqlite3_column_text(statement, 0) else { return }
        let threadID = String(cString: idText)
        index.existingThreadIDs.insert(threadID)

        if sqlite3_column_int(statement, 1) == 1 {
            index.archivedThreadIDs.insert(threadID)
        }

        if columnString(statement, 2) == "subagent" {
            index.subagentThreadIDs.insert(threadID)
        }

        addExecHelperRow(threadID, statement: statement, to: &index)
        addProjectNameRow(threadID, statement: statement, to: &index)
    }

    private static func addExecHelperRow(_ threadID: String, statement: OpaquePointer, to index: inout CodexThreadStateIndex) {
        let source = columnString(statement, 3)
        let hasUserEvent = sqlite3_column_int(statement, 4) != 0
        if source == "exec",
           !hasUserEvent,
           let rolloutPath = columnString(statement, 5),
           rolloutOriginator(at: rolloutPath) == "Codex Desktop" {
            index.execHelperThreadIDs.insert(threadID)
        }
    }

    private static func addProjectNameRow(_ threadID: String, statement: OpaquePointer, to index: inout CodexThreadStateIndex) {
        let origin = columnString(statement, 6)
        let cwd = columnString(statement, 7)
        if let name = origin.flatMap({ projectName(fromGitOriginURL: $0) })
            ?? cwd.flatMap({ projectName(fromPath: $0) }) {
            index.projectNamesByThreadID[threadID] = name
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

}

extension CodexThreadArchiveLookup: CodexThreadStateProviding {}

private struct CodexThreadStateIndexCache {
    let fingerprint: CodexThreadStateDatabaseFingerprint
    let snapshot: CodexThreadStateSnapshot
}

private enum CodexThreadStateSnapshot {
    case missing
    case available(CodexThreadStateIndex)
}

private struct CodexThreadStateIndex {
    var existingThreadIDs: Set<String> = []
    var archivedThreadIDs: Set<String> = []
    var subagentThreadIDs: Set<String> = []
    var execHelperThreadIDs: Set<String> = []
    var projectNamesByThreadID: [String: String] = [:]
}

private enum CodexThreadStateDatabaseFingerprint: Equatable {
    case missing
    case file(
        database: CodexThreadStateFileFingerprint,
        wal: CodexThreadStateFileFingerprint?,
        shm: CodexThreadStateFileFingerprint?
    )
}

private struct CodexThreadStateFileFingerprint: Equatable {
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let fileSize: Int64
}
