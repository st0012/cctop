import Foundation

struct SessionLoadSummary {
    let files: Int
    let decoded: Int
    let live: Int
    let hidden: Int
    let autoHidden: Int
}

extension SessionManager {
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
        sessionManagerLogger.info("loadSessions: \(visibility.codexSubagentThreadIDs.count) codex-subagent")
        sessionManagerLogger.info("loadSessions: \(visibility.codexExecHelperThreadIDs.count) codex-exec-helper")
        sessionManagerLogger.info("loadSessions: \(visibility.archivedClaudeSessionIDs.count) claude-archived")
    }
}
