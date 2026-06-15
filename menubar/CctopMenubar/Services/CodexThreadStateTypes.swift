import SQLite3

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
