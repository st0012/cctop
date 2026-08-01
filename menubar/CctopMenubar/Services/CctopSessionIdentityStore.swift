import CryptoKit
import Foundation

/// Persists cctop-owned session identities separately from live session records.
/// Client references are used only as lookup evidence for clients whose local
/// resume contracts expose a stable UUID.
struct CctopSessionIdentityStore {
    enum StoreError: Error {
        case corruptMapping(String)
        case conflictingExistingIdentities(String)
    }

    private struct Mapping: Codable {
        let cctopSessionId: String
    }

    private let sessionsDir: URL

    init(sessionsDir: URL) {
        self.sessionsDir = sessionsDir
    }

    /// Returns an already-persisted durable identity without creating mapping state.
    func existingIdentity(
        source: String?,
        harnessSessionId: String?,
        legacySessionId: String
    ) throws -> String? {
        guard let evidence = Self.durableEvidence(
            source: source,
            harnessSessionId: harnessSessionId,
            legacySessionId: legacySessionId
        ) else {
            return nil
        }
        let mappingURL = identityDirectory.appendingPathComponent(Self.mappingFileName(for: evidence))
        guard FileManager.default.fileExists(atPath: mappingURL.path) else { return nil }
        return try readMapping(at: mappingURL)
    }

    // Resolution intentionally keeps mapping validation and creation under one flock.
    func resolve(
        source: String?,
        harnessSessionId: String?,
        legacySessionId: String,
        knownExistingIDs: Set<String>? = nil
    ) throws -> String {
        guard let evidence = Self.durableEvidence(
            source: source,
            harnessSessionId: harnessSessionId,
            legacySessionId: legacySessionId
        ) else {
            return Session.makeCctopSessionId()
        }

        let directory = identityDirectory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let mappingURL = directory.appendingPathComponent(Self.mappingFileName(for: evidence))
        var resolved: String?
        try withSessionLock(sessionPath: mappingURL.path) {
            if FileManager.default.fileExists(atPath: mappingURL.path) {
                resolved = try readMapping(at: mappingURL)
                return
            }

            var existing = knownExistingIDs ?? []
            if knownExistingIDs == nil {
                for url in sessionFiles() {
                    guard let session = try? Session.fromFile(path: url.path),
                          Self.durableEvidence(
                            source: session.source,
                            harnessSessionId: session.harnessSessionId,
                            legacySessionId: session.sessionId
                          ) == evidence,
                          Session.isValidCctopSessionId(session.cctopSessionId),
                          let cctopSessionId = session.cctopSessionId else { continue }
                    existing.insert(cctopSessionId)
                }
            }
            guard existing.count <= 1 else {
                throw StoreError.conflictingExistingIdentities(mappingURL.lastPathComponent)
            }

            let cctopSessionId = existing.first ?? Session.makeCctopSessionId()
            try writeMapping(Mapping(cctopSessionId: cctopSessionId), to: mappingURL)
            resolved = cctopSessionId
        }
        guard let resolved else {
            throw StoreError.corruptMapping(mappingURL.lastPathComponent)
        }
        return resolved
    }

    /// Current reliable same-machine resume evidence. OpenCode deliberately remains
    /// record-local, and pi only participates when it supplies a real UUID rather than
    /// the synthetic process fallback.
    static func durableEvidence(
        source: String?,
        harnessSessionId: String?,
        legacySessionId: String
    ) -> String? {
        // The established session-file migration contract treats a missing source as
        // Claude Code; retain that narrow legacy rule without inferring across clients.
        let normalizedSource = source ?? Session.ccSource
        guard [Session.codexSource, Session.ccSource, Session.piSource].contains(normalizedSource) else {
            return nil
        }
        let reference = harnessSessionId.flatMap { $0.isEmpty ? nil : $0 } ?? legacySessionId
        guard let uuid = UUID(uuidString: reference), uuid.uuidString.lowercased() == reference.lowercased() else {
            return nil
        }
        return "\(normalizedSource):\(uuid.uuidString.lowercased())"
    }

    private var identityDirectory: URL {
        if sessionsDir.lastPathComponent == "sessions" {
            return sessionsDir.deletingLastPathComponent()
                .appendingPathComponent("session-identities", isDirectory: true)
        }
        // CCTOP_SESSIONS_DIR may point directly at an isolated test or diagnostic
        // directory. Keep its identities inside that boundary instead of sharing the
        // override's parent with unrelated runs.
        return sessionsDir.appendingPathComponent(".session-identities", isDirectory: true)
    }

    private func sessionFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".tmp") } ?? []
    }

    private static func mappingFileName(for evidence: String) -> String {
        let canonical = "v1:\(evidence.utf8.count):\(evidence)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return "v1-\(digest.map { String(format: "%02x", $0) }.joined()).json"
    }

    private func readMapping(at url: URL) throws -> String {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let mapping = try decoder.decode(Mapping.self, from: Data(contentsOf: url))
        guard Session.isValidCctopSessionId(mapping.cctopSessionId) else {
            throw StoreError.corruptMapping(url.lastPathComponent)
        }
        return mapping.cctopSessionId
    }

    private func writeMapping(_ mapping: Mapping, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(mapping)
        let tempURL = url.appendingPathExtension("\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            guard rename(tempURL.path, url.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
}
