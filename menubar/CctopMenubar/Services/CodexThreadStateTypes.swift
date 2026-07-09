import SQLite3

/// Read-side seam over Codex's local thread state. `CodexThreadArchiveLookup` is the live
/// SQLite-backed implementation; tests substitute in-memory stubs so classification and archive
/// logic can run without a database on disk. `nil` means the lookup could not prove an answer,
/// either because the store was unreadable or because absence is intentionally treated as unknown.
protocol CodexThreadStateProviding {
    func stateIndex(matching threadIDs: Set<String>) -> CodexThreadStateIndex?
    func existingThreadIDs(matching threadIDs: Set<String>) -> Set<String>?
    func archivedThreadIDs(matching threadIDs: Set<String>) -> Set<String>?
    func subagentThreadIDs(matching threadIDs: Set<String>) -> Set<String>?
    func execHelperThreadIDs(matching threadIDs: Set<String>) -> Set<String>?
    func projectNames(matching threadIDs: Set<String>) -> [String: String]?
}

struct CodexThreadStateRequestKey: Hashable {
    let database: CodexThreadStateDatabaseFingerprint
    let threadIDs: Set<String>
}

struct CodexThreadStateIndexCache {
    let snapshot: CodexThreadStateSnapshot
    let rolloutPaths: Set<String>
    let rolloutFingerprints: [CodexThreadStateRolloutFileFingerprint]
}

struct CodexThreadStateLoadResult {
    let snapshot: CodexThreadStateSnapshot
    let rolloutPaths: Set<String>
    let rolloutFingerprints: [CodexThreadStateRolloutFileFingerprint]
}

enum CodexThreadStateSnapshot {
    case missing
    case available(CodexThreadStateIndex)
}

struct CodexThreadStateIndex {
    var existingThreadIDs: Set<String> = []
    var archivedThreadIDs: Set<String> = []
    var subagentThreadIDs: Set<String> = []
    var execHelperThreadIDs: Set<String> = []
    var projectNamesByThreadID: [String: String] = [:]

    mutating func merge(_ other: CodexThreadStateIndex) {
        existingThreadIDs.formUnion(other.existingThreadIDs)
        archivedThreadIDs.formUnion(other.archivedThreadIDs)
        subagentThreadIDs.formUnion(other.subagentThreadIDs)
        execHelperThreadIDs.formUnion(other.execHelperThreadIDs)
        projectNamesByThreadID.merge(other.projectNamesByThreadID) { current, _ in current }
    }

    func filtered(to threadIDs: Set<String>) -> CodexThreadStateIndex {
        CodexThreadStateIndex(
            existingThreadIDs: existingThreadIDs.intersection(threadIDs),
            archivedThreadIDs: archivedThreadIDs.intersection(threadIDs),
            subagentThreadIDs: subagentThreadIDs.intersection(threadIDs),
            execHelperThreadIDs: execHelperThreadIDs.intersection(threadIDs),
            projectNamesByThreadID: projectNamesByThreadID.filter { threadIDs.contains($0.key) }
        )
    }
}

struct CodexThreadStateRolloutTracker {
    var paths: Set<String> = []
    var fingerprints: [String: CodexThreadStateRolloutFileFingerprint] = [:]
}

enum CodexThreadStateDatabaseFingerprint: Equatable, Hashable {
    case missing
    case file(
        database: CodexThreadStateFileFingerprint,
        wal: CodexThreadStateFileFingerprint?,
        shm: CodexThreadStateFileFingerprint?
    )
}

struct CodexThreadStateRolloutFileFingerprint: Equatable {
    let path: String
    let file: CodexThreadStateFileFingerprint?
}

struct CodexThreadStateFileFingerprint: Equatable, Hashable {
    let deviceID: Int64
    let fileID: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let statusChangedSeconds: Int64
    let statusChangedNanoseconds: Int64
    let fileSize: Int64
}

let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension CodexThreadStateProviding {
    func stateIndex(matching threadIDs: Set<String>) -> CodexThreadStateIndex? {
        guard !threadIDs.isEmpty else { return CodexThreadStateIndex() }
        guard let existingThreadIDs = existingThreadIDs(matching: threadIDs) else { return nil }

        var index = CodexThreadStateIndex()
        index.existingThreadIDs = existingThreadIDs
        index.archivedThreadIDs = archivedThreadIDs(matching: threadIDs) ?? []
        index.subagentThreadIDs = subagentThreadIDs(matching: threadIDs) ?? []
        index.execHelperThreadIDs = execHelperThreadIDs(matching: threadIDs) ?? []
        index.projectNamesByThreadID = projectNames(matching: threadIDs) ?? [:]
        return index
    }
}
