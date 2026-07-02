import Darwin
import Foundation

struct SessionLoadSummary: Equatable {
    let files: Int
    let decoded: Int
    let live: Int
    let hidden: Int
    let autoHidden: Int
}

struct SessionLoadLogSignature: Equatable {
    let summary: SessionLoadSummary
    let archivedCodexThreadIDs: Int
    let missingCodexDesktopThreadIDs: Int
    let codexSubagentThreadIDs: Int
    let codexExecHelperThreadIDs: Int
    let archivedClaudeSessionIDs: Int
}

struct SessionFileCacheEntry {
    let fingerprint: SessionFileFingerprint
    let session: Session
}

struct SessionFileFingerprint: Equatable {
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let fileSize: Int64
}

extension SessionManager {
    func decodedSessions(from jsonFiles: [URL]) -> [(url: URL, session: Session)] {
        let currentPaths = Set(jsonFiles.map(\.path))
        sessionFileCache = sessionFileCache.filter { currentPaths.contains($0.key) }

        return jsonFiles.compactMap { url in
            guard let fingerprint = sessionFileFingerprint(for: url) else {
                sessionFileCache.removeValue(forKey: url.path)
                sessionManagerLogger.warning("loadSessions: could not stat \(url.lastPathComponent, privacy: .public)")
                return nil
            }
            if let cached = sessionFileCache[url.path], cached.fingerprint == fingerprint {
                return (url, cached.session)
            }
            guard let data = try? Data(contentsOf: url) else {
                sessionFileCache.removeValue(forKey: url.path)
                sessionManagerLogger.warning("loadSessions: could not read \(url.lastPathComponent, privacy: .public)")
                return nil
            }
            do {
                let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: data)
                sessionFileCache[url.path] = SessionFileCacheEntry(
                    fingerprint: fingerprint,
                    session: session
                )
                return (url, session)
            } catch {
                sessionFileCache.removeValue(forKey: url.path)
                sessionManagerLogger.error("loadSessions: decode failed \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                return nil
            }
        }
    }

    private func sessionFileFingerprint(for url: URL) -> SessionFileFingerprint? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return SessionFileFingerprint(
            modifiedSeconds: Int(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec),
            fileSize: Int64(info.st_size)
        )
    }

    func currentStatusesByStableKey() -> [String: SessionStatus] {
        Dictionary(
            sessions.map { (SessionIdentityPolicy.stableKey(for: $0), $0.status) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func sessionJSONFiles(in files: [URL]) -> [URL] {
        files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".tmp") }
    }

    func logLoadSummary(_ summary: SessionLoadSummary, classification: SessionClassificationSnapshot) {
        let signature = SessionLoadLogSignature(
            summary: summary,
            archivedCodexThreadIDs: classification.archivedCodexThreadIDs.count,
            missingCodexDesktopThreadIDs: classification.missingCodexDesktopThreadIDs.count,
            codexSubagentThreadIDs: classification.codexSubagentThreadIDs.count,
            codexExecHelperThreadIDs: classification.codexExecHelperThreadIDs.count,
            archivedClaudeSessionIDs: classification.archivedClaudeSessionIDs.count
        )
        guard signature != lastLoadLogSignature else { return }
        lastLoadLogSignature = signature

        sessionManagerLogger.info("loadSessions: \(summary.files) files, \(summary.decoded) decoded")
        sessionManagerLogger.info(
            "loadSessions: \(summary.live) visible candidates, \(summary.hidden) hidden, \(summary.autoHidden) auto-hidden"
        )
        sessionManagerLogger.info("loadSessions: \(classification.archivedCodexThreadIDs.count) codex-archived")
        sessionManagerLogger.info("loadSessions: \(classification.missingCodexDesktopThreadIDs.count) codex-missing-state")
        sessionManagerLogger.info("loadSessions: \(classification.codexSubagentThreadIDs.count) codex-subagent")
        sessionManagerLogger.info("loadSessions: \(classification.codexExecHelperThreadIDs.count) codex-exec-helper")
        sessionManagerLogger.info("loadSessions: \(classification.archivedClaudeSessionIDs.count) claude-archived")
    }
}
