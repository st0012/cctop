import Foundation

struct SessionLoadSummary {
    let files: Int
    let decoded: Int
    let live: Int
    let hidden: Int
    let autoHidden: Int
}

extension SessionManager {
    func decodedSessions(from jsonFiles: [URL]) -> [(url: URL, session: Session)] {
        jsonFiles.compactMap { url in
            guard let data = try? Data(contentsOf: url) else {
                sessionManagerLogger.warning("loadSessions: could not read \(url.lastPathComponent, privacy: .public)")
                return nil
            }
            do {
                let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: data)
                return (url, session)
            } catch {
                sessionManagerLogger.error("loadSessions: decode failed \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                return nil
            }
        }
    }

    /// Derives lifecycle-stamped candidates and the visibility classification for one load pass,
    /// reading desktop archive state and process liveness through the injected data sources.
    func deriveVisibility(from visibleDecoded: [(url: URL, session: Session)]) -> SessionVisibilitySnapshot {
        let claudeMetadata = Self.claudeDesktopMetadataSnapshot(
            in: visibleDecoded.map(\.session),
            claudeDesktopSessions: dataSources.claudeDesktopSessions
        )
        let candidates = Self.buildCandidates(
            visibleDecoded,
            now: dataSources.now(),
            desktopAppConnectionLookup: dataSources.desktopAppConnection,
            claudeMetadata: claudeMetadata,
            codexThreads: dataSources.codexThreads,
            processAlive: dataSources.processAlive
        )
        return Self.visibilitySnapshot(
            in: candidates,
            claudeMetadata: claudeMetadata,
            codexThreads: dataSources.codexThreads
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

    func logLoadSummary(_ summary: SessionLoadSummary, visibility: SessionVisibilitySnapshot) {
        sessionManagerLogger.info("loadSessions: \(summary.files) files, \(summary.decoded) decoded")
        sessionManagerLogger.info(
            "loadSessions: \(summary.live) visible candidates, \(summary.hidden) hidden, \(summary.autoHidden) auto-hidden"
        )
        sessionManagerLogger.info("loadSessions: \(visibility.archivedCodexThreadIDs.count) codex-archived")
        sessionManagerLogger.info("loadSessions: \(visibility.missingCodexDesktopThreadIDs.count) codex-missing-state")
        sessionManagerLogger.info("loadSessions: \(visibility.codexSubagentThreadIDs.count) codex-subagent")
        sessionManagerLogger.info("loadSessions: \(visibility.codexExecHelperThreadIDs.count) codex-exec-helper")
        sessionManagerLogger.info("loadSessions: \(visibility.archivedClaudeSessionIDs.count) claude-archived")
    }
}
