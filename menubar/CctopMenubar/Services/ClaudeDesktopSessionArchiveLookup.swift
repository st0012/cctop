import Foundation

/// Read-side seam over Claude Desktop's session metadata store. The live implementation scans
/// `~/Library/Application Support/Claude/claude-code-sessions`; tests substitute stubs so
/// archive/orphan filtering can run without metadata files on disk. `nil` keeps the lookup's
/// contract: the store exists but a matching read was uncertain.
protocol ClaudeDesktopSessionStateProviding {
    func archivedSessionIDs(matching sessionIDs: Set<String>) -> Set<String>?
    func metadataSnapshot(matching sessionIDs: Set<String>) -> ClaudeDesktopSessionMetadataSnapshot?
}

final class ClaudeDesktopSessionArchiveLookup {
    typealias MetadataDataReader = (URL) -> Data?

    let sessionsDirectory: String
    private let dataReader: MetadataDataReader
    private var indexCache: ClaudeDesktopMetadataIndexCache?
    private let cacheLock = NSLock()

    init(
        sessionsDirectory: String = Config.claudeCodeSessionsDir(),
        dataReader: @escaping MetadataDataReader = { try? Data(contentsOf: $0) }
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.dataReader = dataReader
    }

    /// Returns the subset of Claude Code `session_id`s whose Claude Desktop metadata is archived,
    /// or `nil` when a matching metadata read is uncertain. A missing metadata directory returns
    /// `[]` so machines without Claude Desktop keep the normal lifecycle behavior.
    func archivedSessionIDs(matching sessionIDs: Set<String>) -> Set<String>? {
        metadataSnapshot(matching: sessionIDs)?.archivedSessionIDs
    }

    /// Returns Claude metadata matches for validation and archive filtering, or `nil` when the
    /// metadata store exists but cannot be read safely.
    func metadataSnapshot(matching sessionIDs: Set<String>) -> ClaudeDesktopSessionMetadataSnapshot? {
        guard !sessionIDs.isEmpty else { return ClaudeDesktopSessionMetadataSnapshot() }

        let rootURL = URL(fileURLWithPath: sessionsDirectory)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return ClaudeDesktopSessionMetadataSnapshot(isAuthoritative: false)
        }
        guard isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                  at: rootURL,
                  includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
              ) else {
            return nil
        }

        let metadataURLs = metadataURLs(in: enumerator)
        guard let fingerprint = metadataFingerprint(for: metadataURLs) else { return nil }
        if let cached = cachedIndex(fingerprint: fingerprint) {
            return cached.snapshot(matching: sessionIDs)
        }

        guard let index = metadataIndex(for: metadataURLs) else { return nil }
        cacheIndex(index, fingerprint: fingerprint)
        return index.snapshot(matching: sessionIDs)
    }

    private func metadataURLs(in enumerator: FileManager.DirectoryEnumerator) -> [URL] {
        enumerator.compactMap { entry in
            guard let url = entry as? URL, isClaudeDesktopMetadataURL(url) else { return nil }
            return url
        }
    }

    private func metadataFingerprint(for urls: [URL]) -> [ClaudeDesktopMetadataFileFingerprint]? {
        var fingerprint: [ClaudeDesktopMetadataFileFingerprint] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                return nil
            }
            fingerprint.append(ClaudeDesktopMetadataFileFingerprint(
                path: url.path,
                modificationDate: values.contentModificationDate ?? .distantPast,
                fileSize: values.fileSize ?? -1
            ))
        }
        return fingerprint.sorted { $0.path < $1.path }
    }

    private func cachedIndex(
        fingerprint: [ClaudeDesktopMetadataFileFingerprint]
    ) -> ClaudeDesktopMetadataIndex? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let indexCache,
              indexCache.fingerprint == fingerprint else { return nil }
        return indexCache.index
    }

    private func cacheIndex(
        _ index: ClaudeDesktopMetadataIndex,
        fingerprint: [ClaudeDesktopMetadataFileFingerprint]
    ) {
        cacheLock.lock()
        indexCache = ClaudeDesktopMetadataIndexCache(
            fingerprint: fingerprint,
            index: index
        )
        cacheLock.unlock()
    }

    private func isClaudeDesktopMetadataURL(_ url: URL) -> Bool {
        url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_")
    }

    private func metadataIndex(for urls: [URL]) -> ClaudeDesktopMetadataIndex? {
        var latestBySessionID: [String: ClaudeArchiveMatch] = [:]
        var uncertainSessionIDs: Set<String> = []
        var uncertainContents: [String] = []

        for url in urls {
            guard let data = dataReader(url),
                  let content = String(data: data, encoding: .utf8) else {
                return nil
            }
            let scannedSessionIDs = cliSessionIDs(in: content)
            if scannedSessionIDs.values.isEmpty {
                if content.contains(#""cliSessionId""#) {
                    uncertainContents.append(content)
                }
                continue
            }
            if scannedSessionIDs.sawUnparseableValue {
                uncertainContents.append(content)
            }
            guard let metadata = try? JSONDecoder().decode(ClaudeDesktopSessionMetadata.self, from: data) else {
                uncertainSessionIDs.formUnion(scannedSessionIDs.values)
                continue
            }
            guard let cliSessionId = metadata.cliSessionId else { continue }

            let match = ClaudeArchiveMatch(
                isArchived: metadata.isArchived == true,
                projectName: Self.projectName(originCwd: metadata.originCwd, worktreeName: metadata.worktreeName),
                recencyKey: metadata.lastActivityAt ?? metadata.createdAt ?? .missing,
                path: url.path
            )
            if let current = latestBySessionID[cliSessionId],
               !match.isNewer(than: current) {
                continue
            }
            latestBySessionID[cliSessionId] = match
        }

        return ClaudeDesktopMetadataIndex(
            latestBySessionID: latestBySessionID,
            uncertainSessionIDs: uncertainSessionIDs,
            uncertainContents: uncertainContents
        )
    }

    private func cliSessionIDs(in content: String) -> ClaudeCLISessionIDScan {
        var cursor = content.startIndex
        var values: [String] = []
        var sawUnparseableValue = false

        while let keyRange = content[cursor...].range(of: #""cliSessionId""#) {
            cursor = keyRange.upperBound
            guard let colonRange = content[cursor...].range(of: ":") else {
                sawUnparseableValue = true
                continue
            }
            cursor = colonRange.upperBound
            while cursor < content.endIndex, content[cursor].isWhitespace {
                cursor = content.index(after: cursor)
            }
            guard cursor < content.endIndex, content[cursor] == "\"" else {
                sawUnparseableValue = true
                continue
            }
            cursor = content.index(after: cursor)
            guard let value = quotedValue(in: content, cursor: &cursor) else {
                sawUnparseableValue = true
                continue
            }
            values.append(value)
        }

        return ClaudeCLISessionIDScan(values: values, sawUnparseableValue: sawUnparseableValue)
    }

    private func quotedValue(in content: String, cursor: inout String.Index) -> String? {
        var value = ""
        var escaped = false
        while cursor < content.endIndex {
            let character = content[cursor]
            cursor = content.index(after: cursor)

            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return value
            } else {
                value.append(character)
            }
        }

        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func projectName(originCwd: String?, worktreeName: String?) -> String? {
        basename(fromPath: originCwd) ?? nonEmpty(worktreeName)
    }

    private static func basename(fromPath path: String?) -> String? {
        guard let path = nonEmpty(path) else { return nil }
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else { return nil }
        return nonEmpty((normalized as NSString).lastPathComponent)
    }
}

extension ClaudeDesktopSessionArchiveLookup: ClaudeDesktopSessionStateProviding {}

private struct ClaudeDesktopMetadataFileFingerprint: Equatable {
    let path: String
    let modificationDate: Date
    let fileSize: Int
}

private struct ClaudeDesktopMetadataIndexCache {
    let fingerprint: [ClaudeDesktopMetadataFileFingerprint]
    let index: ClaudeDesktopMetadataIndex
}

private struct ClaudeDesktopMetadataIndex {
    let latestBySessionID: [String: ClaudeArchiveMatch]
    let uncertainSessionIDs: Set<String>
    let uncertainContents: [String]

    func snapshot(matching sessionIDs: Set<String>) -> ClaudeDesktopSessionMetadataSnapshot? {
        guard uncertainSessionIDs.isDisjoint(with: sessionIDs),
              !uncertainContents.contains(where: { content in
                  sessionIDs.contains(where: { content.contains($0) })
              }) else {
            return nil
        }

        let latestMatches = latestBySessionID.filter { sessionIDs.contains($0.key) }
        return ClaudeDesktopSessionMetadataSnapshot(
            matchedSessionIDs: Set(latestMatches.keys),
            archivedSessionIDs: Set(latestMatches.compactMap { sessionID, match in
                match.isArchived ? sessionID : nil
            }),
            projectNamesBySessionID: latestMatches.compactMapValues(\.projectName),
            isAuthoritative: true
        )
    }
}

struct ClaudeDesktopSessionMetadataSnapshot: Equatable {
    let matchedSessionIDs: Set<String>
    let archivedSessionIDs: Set<String>
    let projectNamesBySessionID: [String: String]
    let isAuthoritative: Bool

    init(
        matchedSessionIDs: Set<String> = [],
        archivedSessionIDs: Set<String> = [],
        projectNamesBySessionID: [String: String] = [:],
        isAuthoritative: Bool = true
    ) {
        self.matchedSessionIDs = matchedSessionIDs
        self.archivedSessionIDs = archivedSessionIDs
        self.projectNamesBySessionID = projectNamesBySessionID
        self.isAuthoritative = isAuthoritative
    }
}

private struct ClaudeDesktopSessionMetadata: Decodable {
    let cliSessionId: String?
    let isArchived: Bool?
    let originCwd: String?
    let worktreeName: String?
    let lastActivityAt: ClaudeArchiveRecencyKey?
    let createdAt: ClaudeArchiveRecencyKey?

    private enum CodingKeys: String, CodingKey {
        case cliSessionId
        case isArchived
        case originCwd
        case worktreeName
        case lastActivityAt
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cliSessionId = try container.decodeIfPresent(String.self, forKey: .cliSessionId)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived)
        originCwd = Self.decodeStringIfPresent(from: container, forKey: .originCwd)
        worktreeName = Self.decodeStringIfPresent(from: container, forKey: .worktreeName)
        lastActivityAt = Self.decodeRecencyKey(from: container, forKey: .lastActivityAt)
        createdAt = Self.decodeRecencyKey(from: container, forKey: .createdAt)
    }

    private static func decodeStringIfPresent(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        try? container.decodeIfPresent(String.self, forKey: key)
    }

    private static func decodeRecencyKey(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> ClaudeArchiveRecencyKey? {
        if let integer = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return .number(Double(integer))
        }
        if let double = try? container.decodeIfPresent(Double.self, forKey: key) {
            return .number(double)
        }
        if let string = try? container.decodeIfPresent(String.self, forKey: key) {
            return .string(string)
        }
        return nil
    }
}

private struct ClaudeArchiveRecencyKey: Comparable {
    static let missing = ClaudeArchiveRecencyKey(number: nil, text: "")

    let number: Double?
    let text: String

    static func number(_ value: Double) -> ClaudeArchiveRecencyKey {
        ClaudeArchiveRecencyKey(number: value, text: String(value))
    }

    static func string(_ value: String) -> ClaudeArchiveRecencyKey {
        ClaudeArchiveRecencyKey(number: Double(value), text: value)
    }

    static func == (lhs: ClaudeArchiveRecencyKey, rhs: ClaudeArchiveRecencyKey) -> Bool {
        switch (lhs.number, rhs.number) {
        case let (lhsNumber?, rhsNumber?):
            return lhsNumber == rhsNumber
        default:
            return lhs.text == rhs.text
        }
    }

    static func < (lhs: ClaudeArchiveRecencyKey, rhs: ClaudeArchiveRecencyKey) -> Bool {
        switch (lhs.number, rhs.number) {
        case let (lhsNumber?, rhsNumber?):
            return lhsNumber < rhsNumber
        case (_?, nil) where rhs.text.isEmpty:
            return false
        case (nil, _?) where lhs.text.isEmpty:
            return true
        default:
            return lhs.text < rhs.text
        }
    }
}

private struct ClaudeArchiveMatch {
    let isArchived: Bool
    let projectName: String?
    let recencyKey: ClaudeArchiveRecencyKey
    let path: String

    func isNewer(than other: ClaudeArchiveMatch) -> Bool {
        if recencyKey != other.recencyKey {
            return recencyKey > other.recencyKey
        }
        return path > other.path
    }
}

private struct ClaudeCLISessionIDScan {
    let values: [String]
    let sawUnparseableValue: Bool
}
