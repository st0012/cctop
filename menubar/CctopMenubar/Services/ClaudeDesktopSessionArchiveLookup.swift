import Foundation

/// Read-side seam over Claude Desktop's session metadata store. The live implementation scans
/// `~/Library/Application Support/Claude/claude-code-sessions`; tests substitute stubs so
/// archive/orphan filtering can run without metadata files on disk. `nil` keeps the lookup's
/// contract: the store exists but a matching read was uncertain.
protocol ClaudeDesktopSessionStateProviding {
    func archivedSessionIDs(matching sessionIDs: Set<String>) -> Set<String>?
    func metadataSnapshot(matching sessionIDs: Set<String>) -> ClaudeDesktopSessionMetadataSnapshot?
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
                  includingPropertiesForKeys: [.contentModificationDateKey]
              ) else {
            return nil
        }

        var latestBySessionID: [String: ClaudeArchiveMatch] = [:]
        for case let url as URL in enumerator where isClaudeDesktopMetadataURL(url) {
            switch metadataMatch(at: url, matching: sessionIDs) {
            case .skip:
                continue
            case .uncertain:
                return nil
            case let .match(sessionID, match):
                if let current = latestBySessionID[sessionID],
                   !match.isNewer(than: current) {
                    continue
                }
                latestBySessionID[sessionID] = match
            }
        }

        return ClaudeDesktopSessionMetadataSnapshot(
            matchedSessionIDs: Set(latestBySessionID.keys),
            archivedSessionIDs: Set(latestBySessionID.compactMap { sessionID, match in
                match.isArchived ? sessionID : nil
            }),
            projectNamesBySessionID: latestBySessionID.compactMapValues(\.projectName),
            isAuthoritative: true
        )
    }

    private func isClaudeDesktopMetadataURL(_ url: URL) -> Bool {
        url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_")
    }

    private func metadataMatch(at url: URL, matching sessionIDs: Set<String>) -> ClaudeMetadataFileMatch {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return .uncertain
        }
        let scannedSessionIDs = cliSessionIDs(in: content)
        guard !scannedSessionIDs.values.isEmpty else {
            if content.contains(#""cliSessionId""#),
               sessionIDs.contains(where: { content.contains($0) }) {
                return .uncertain
            }
            return .skip
        }
        guard scannedSessionIDs.values.contains(where: { sessionIDs.contains($0) }) else {
            if scannedSessionIDs.sawUnparseableValue,
               sessionIDs.contains(where: { content.contains($0) }) {
                return .uncertain
            }
            return .skip
        }
        guard let metadata = try? JSONDecoder().decode(ClaudeDesktopSessionMetadata.self, from: data) else {
            return .uncertain
        }
        guard let cliSessionId = metadata.cliSessionId,
              sessionIDs.contains(cliSessionId) else { return .skip }

        let match = ClaudeArchiveMatch(
            isArchived: metadata.isArchived == true,
            projectName: Self.projectName(originCwd: metadata.originCwd, worktreeName: metadata.worktreeName),
            recencyKey: metadata.lastActivityAt ?? metadata.createdAt ?? .missing,
            path: url.path
        )
        return .match(cliSessionId, match)
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

private enum ClaudeMetadataFileMatch {
    case skip
    case uncertain
    case match(String, ClaudeArchiveMatch)
}

private struct ClaudeCLISessionIDScan {
    let values: [String]
    let sawUnparseableValue: Bool
}
