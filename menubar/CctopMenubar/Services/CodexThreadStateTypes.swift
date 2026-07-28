import Foundation
import SQLite3

/// Codex persists `SessionSource` as either an unquoted scalar (`cli`, `vscode`, ...)
/// or an externally tagged JSON object for sources carrying metadata. Keep decoding in one
/// typed boundary so visibility policy never depends on display strings such as `thread_source`.
enum CodexSessionSource: Equatable, Decodable {
    case cli
    case vscode
    case exec
    case mcp
    case custom(String)
    case internalHelper
    case subagent(parentThreadID: String?)
    case unknown

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            switch value {
            case "cli": self = .cli
            case "vscode": self = .vscode
            case "exec": self = .exec
            case "mcp": self = .mcp
            case "unknown": self = .unknown
            default: self = .unknown
            }
            return
        }

        let container = try decoder.container(keyedBy: CodexSourceCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected one Codex source tag")
            )
        }
        switch key.stringValue {
        case "custom":
            self = .custom(try container.decode(String.self, forKey: key))
        case "internal":
            _ = try container.decode(String.self, forKey: key)
            self = .internalHelper
        case "subagent":
            let source = try container.decode(CodexSubagentSource.self, forKey: key)
            self = .subagent(parentThreadID: source.parentThreadID)
        default:
            self = .unknown
        }
    }
}

enum CodexStoredSessionSource: Equatable {
    case decoded(CodexSessionSource)
    case missing
    case malformed

    init(storedValue: String?) {
        guard let storedValue = storedValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !storedValue.isEmpty else {
            self = .missing
            return
        }

        let decoder = JSONDecoder()
        if let source = try? decoder.decode(CodexSessionSource.self, from: Data(storedValue.utf8)) {
            self = .decoded(source)
            return
        }
        if let first = storedValue.first, "{[\"".contains(first) {
            self = .malformed
            return
        }
        guard let quoted = try? JSONEncoder().encode(storedValue),
              let source = try? decoder.decode(CodexSessionSource.self, from: quoted) else {
            self = .malformed
            return
        }
        self = .decoded(source)
    }

    func delegationClassification(spawnParentThreadID: String?) -> CodexThreadDelegationClassification {
        switch self {
        case .decoded(.cli), .decoded(.vscode):
            return spawnParentThreadID == nil ? .interactiveRoot : .contradictory
        case .decoded(.internalHelper):
            return .internalHelper
        case .decoded(.subagent(let expectedParentThreadID)):
            if let expectedParentThreadID, let spawnParentThreadID,
               expectedParentThreadID != spawnParentThreadID {
                return .contradictory
            }
            return .internalHelper
        case .decoded(.exec), .decoded(.mcp), .decoded(.custom):
            return spawnParentThreadID == nil ? .otherVisible : .contradictory
        case .decoded(.unknown), .missing, .malformed:
            return .uncertain
        }
    }
}

enum CodexThreadDelegationClassification: Equatable {
    case interactiveRoot
    case internalHelper
    case otherVisible
    case uncertain
    case contradictory
}

private struct CodexSourceCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private enum CodexSubagentSource: Decodable {
    case threadSpawn(parentThreadID: String)
    case other

    var parentThreadID: String? {
        guard case .threadSpawn(let parentThreadID) = self else { return nil }
        return parentThreadID
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self), !value.isEmpty {
            self = .other
            return
        }

        let container = try decoder.container(keyedBy: CodexSourceCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected one Codex subagent source tag")
            )
        }
        if key.stringValue == "thread_spawn" {
            let payload = try container.decode(CodexThreadSpawnSource.self, forKey: key)
            self = .threadSpawn(parentThreadID: payload.parentThreadID)
        } else {
            self = .other
        }
    }
}

private struct CodexThreadSpawnSource: Decodable {
    let parentThreadID: String

    enum CodingKeys: String, CodingKey {
        case parentThreadID = "parent_thread_id"
    }
}

/// Read-side seam over Codex's local thread state. `CodexThreadArchiveLookup` is the live
/// SQLite-backed implementation; tests substitute in-memory stubs so classification and archive
/// logic can run without a database on disk. `stateSnapshot` distinguishes confirmed database
/// absence from a transient unreadable store; the narrower optional methods retain their existing
/// caller-specific fail-open/fail-safe meanings.
protocol CodexThreadStateProviding {
    func stateSnapshot(matching threadIDs: Set<String>) -> CodexThreadStateSnapshot
    func stateIndex(matching threadIDs: Set<String>) -> CodexThreadStateIndex?
    func existingThreadIDs(matching threadIDs: Set<String>) -> Set<String>?
    func archivedThreadIDs(matching threadIDs: Set<String>) -> Set<String>?
    func internalHelperThreadIDs(matching threadIDs: Set<String>) -> Set<String>?
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
    case unreadable
}

struct CodexThreadStateIndex {
    var existingThreadIDs: Set<String> = []
    var archivedThreadIDs: Set<String> = []
    var internalHelperThreadIDs: Set<String> = []
    var interactiveRootThreadIDs: Set<String> = []
    var knownNoSpawnEdgeThreadIDs: Set<String> = []
    var uncertainDelegationThreadIDs: Set<String> = []
    var contradictoryDelegationThreadIDs: Set<String> = []
    var execHelperThreadIDs: Set<String> = []
    var projectNamesByThreadID: [String: String] = [:]
    var unknownThreadIDs: Set<String> = []

    mutating func merge(_ other: CodexThreadStateIndex) {
        existingThreadIDs.formUnion(other.existingThreadIDs)
        archivedThreadIDs.formUnion(other.archivedThreadIDs)
        internalHelperThreadIDs.formUnion(other.internalHelperThreadIDs)
        interactiveRootThreadIDs.formUnion(other.interactiveRootThreadIDs)
        knownNoSpawnEdgeThreadIDs.formUnion(other.knownNoSpawnEdgeThreadIDs)
        uncertainDelegationThreadIDs.formUnion(other.uncertainDelegationThreadIDs)
        contradictoryDelegationThreadIDs.formUnion(other.contradictoryDelegationThreadIDs)
        execHelperThreadIDs.formUnion(other.execHelperThreadIDs)
        projectNamesByThreadID.merge(other.projectNamesByThreadID) { current, _ in current }
        unknownThreadIDs.formUnion(other.unknownThreadIDs)
    }

    func filtered(to threadIDs: Set<String>) -> CodexThreadStateIndex {
        CodexThreadStateIndex(
            existingThreadIDs: existingThreadIDs.intersection(threadIDs),
            archivedThreadIDs: archivedThreadIDs.intersection(threadIDs),
            internalHelperThreadIDs: internalHelperThreadIDs.intersection(threadIDs),
            interactiveRootThreadIDs: interactiveRootThreadIDs.intersection(threadIDs),
            knownNoSpawnEdgeThreadIDs: knownNoSpawnEdgeThreadIDs.intersection(threadIDs),
            uncertainDelegationThreadIDs: uncertainDelegationThreadIDs.intersection(threadIDs),
            contradictoryDelegationThreadIDs: contradictoryDelegationThreadIDs.intersection(threadIDs),
            execHelperThreadIDs: execHelperThreadIDs.intersection(threadIDs),
            projectNamesByThreadID: projectNamesByThreadID.filter { threadIDs.contains($0.key) },
            unknownThreadIDs: unknownThreadIDs.intersection(threadIDs)
        )
    }
}

/// Display classification remembers authoritative per-thread facts across transient state-store
/// failures. Coverage is separate from positive sets because a successfully absent thread is a
/// meaningful "missing" classification. The memory is pruned to the current request every pass.
struct CodexThreadClassificationMemory {
    private var index = CodexThreadStateIndex()
    private var resolvedThreadIDs: Set<String> = []

    mutating func effectiveIndex(
        from snapshot: CodexThreadStateSnapshot,
        matching threadIDs: Set<String>
    ) -> CodexThreadStateIndex? {
        switch snapshot {
        case .missing:
            index = CodexThreadStateIndex()
            resolvedThreadIDs = []
            return nil
        case .unreadable:
            return retainKnownState(matching: threadIDs)
        case .available(let authoritative):
            return replaceResolvedState(authoritative, matching: threadIDs)
        }
    }

    private mutating func retainKnownState(matching threadIDs: Set<String>) -> CodexThreadStateIndex {
        let retainedThreadIDs = resolvedThreadIDs.intersection(threadIDs)
        var effective = index.filtered(to: retainedThreadIDs)
        effective.unknownThreadIDs = threadIDs.subtracting(retainedThreadIDs)
        index = effective.filtered(to: retainedThreadIDs)
        index.unknownThreadIDs = []
        resolvedThreadIDs = retainedThreadIDs
        return effective
    }

    private mutating func replaceResolvedState(
        _ authoritative: CodexThreadStateIndex,
        matching threadIDs: Set<String>
    ) -> CodexThreadStateIndex {
        let unknownThreadIDs = authoritative.unknownThreadIDs.intersection(threadIDs)
        let resolvedNow = threadIDs.subtracting(unknownThreadIDs)
        let retainedThreadIDs = unknownThreadIDs.intersection(resolvedThreadIDs)
        let effectiveResolvedThreadIDs = resolvedNow.union(retainedThreadIDs)

        var effective = authoritative.filtered(to: resolvedNow)
        effective.merge(index.filtered(to: retainedThreadIDs))
        effective.unknownThreadIDs = unknownThreadIDs.subtracting(retainedThreadIDs)

        index = effective.filtered(to: effectiveResolvedThreadIDs)
        index.unknownThreadIDs = []
        resolvedThreadIDs = effectiveResolvedThreadIDs
        return effective
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
    func stateSnapshot(matching threadIDs: Set<String>) -> CodexThreadStateSnapshot {
        guard let index = stateIndex(matching: threadIDs) else { return .unreadable }
        return .available(index)
    }

    func stateIndex(matching threadIDs: Set<String>) -> CodexThreadStateIndex? {
        guard !threadIDs.isEmpty else { return CodexThreadStateIndex() }
        guard let existingThreadIDs = existingThreadIDs(matching: threadIDs) else { return nil }

        var index = CodexThreadStateIndex()
        index.existingThreadIDs = existingThreadIDs
        index.archivedThreadIDs = archivedThreadIDs(matching: threadIDs) ?? []
        index.internalHelperThreadIDs = internalHelperThreadIDs(matching: threadIDs) ?? []
        index.execHelperThreadIDs = execHelperThreadIDs(matching: threadIDs) ?? []
        index.projectNamesByThreadID = projectNames(matching: threadIDs) ?? [:]
        return index
    }
}
