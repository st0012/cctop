import Foundation

struct ClaudeDesktopSessionArchiveLookup {
    let sessionsDirectory: String

    init(sessionsDirectory: String = Config.claudeCodeSessionsDir()) {
        self.sessionsDirectory = sessionsDirectory
    }

    /// Returns the subset of Claude Code `session_id`s whose Claude Desktop metadata is archived,
    /// or `nil` when a matching metadata read is uncertain. A missing metadata directory returns
    /// `[]` so machines without Claude Desktop keep the normal lifecycle behavior.
    func archivedSessionIDs(matching sessionIDs: Set<String>) -> Set<String>? {
        guard !sessionIDs.isEmpty else { return [] }

        let rootURL = URL(fileURLWithPath: sessionsDirectory)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return []
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
            guard let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8) else {
                return nil
            }
            guard sessionIDs.contains(where: { content.contains($0) }) else { continue }
            guard let metadata = try? JSONDecoder().decode(ClaudeDesktopSessionMetadata.self, from: data) else {
                return nil
            }
            guard let cliSessionId = metadata.cliSessionId,
                  sessionIDs.contains(cliSessionId) else { continue }

            let match = ClaudeArchiveMatch(
                isArchived: metadata.isArchived == true,
                recencyKey: metadata.lastActivityAt ?? metadata.createdAt ?? .missing,
                path: url.path
            )
            if let current = latestBySessionID[cliSessionId],
               !match.isNewer(than: current) {
                continue
            }
            latestBySessionID[cliSessionId] = match
        }

        return Set(latestBySessionID.compactMap { sessionID, match in
            match.isArchived ? sessionID : nil
        })
    }

    private func isClaudeDesktopMetadataURL(_ url: URL) -> Bool {
        url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_")
    }
}

private struct ClaudeDesktopSessionMetadata: Decodable {
    let cliSessionId: String?
    let isArchived: Bool?
    let lastActivityAt: ClaudeArchiveRecencyKey?
    let createdAt: ClaudeArchiveRecencyKey?

    private enum CodingKeys: String, CodingKey {
        case cliSessionId
        case isArchived
        case lastActivityAt
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cliSessionId = try container.decodeIfPresent(String.self, forKey: .cliSessionId)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived)
        lastActivityAt = Self.decodeRecencyKey(from: container, forKey: .lastActivityAt)
        createdAt = Self.decodeRecencyKey(from: container, forKey: .createdAt)
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
    let recencyKey: ClaudeArchiveRecencyKey
    let path: String

    func isNewer(than other: ClaudeArchiveMatch) -> Bool {
        if recencyKey != other.recencyKey {
            return recencyKey > other.recencyKey
        }
        return path > other.path
    }
}
