import Foundation
import os.log

private let logger = Logger(
    subsystem: "com.st0012.CctopMenubar",
    category: "HistoryManager"
)

@MainActor
class HistoryManager: ObservableObject {
    @Published var recentProjects: [RecentProject] = []

    let historyDir: URL
    static let maxFiles = 50
    static let maxAgeDays = 30
    private(set) var lastDecodedHistorySessions: [SessionData] = []
    private var lastRebuildFingerprint: HistoryRebuildFingerprint?

    init(historyDir: URL = URL(fileURLWithPath: Config.historyDir())) {
        self.historyDir = historyDir
        rebuildRecentProjects()
    }

    // MARK: - Archiving

    /// Archive a dead session to the history directory.
    /// Sets `endedAt`, writes to history, prunes old files, and returns success.
    /// Codex conversations and Claude Desktop sessions are not archived as project-history rows.
    @discardableResult
    func archiveSession(_ session: SessionData) -> Bool {
        if session.isCodex || session.isClaudeDesktopHost {
            logger.info("skipping archive for retained session \(session.sessionId, privacy: .public)")
            return false
        }
        var archived = session
        archived.endedAt = archived.endedAt ?? Date()

        let safeName = sanitizeFilenameComponent(session.projectName)
        let timestamp = ISO8601DateFormatter.archiveFormatter
            .string(from: archived.endedAt!)
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(safeName)_\(timestamp).json"
        let path = historyDir
            .appendingPathComponent(filename).path

        do {
            try archived.writeToFile(path: path)
            logger.info("archived session \(session.sessionId, privacy: .public) to \(filename, privacy: .public)")
        } catch {
            logger.error("failed to archive \(session.sessionId, privacy: .public): \(error, privacy: .public)")
            return false
        }

        pruneHistory()
        return true
    }

    // MARK: - Recent Projects

    /// Rebuild the cached recent projects list from history files.
    @discardableResult
    func rebuildRecentProjects(
        excludingActive activePaths: Set<String> = []
    ) -> Bool {
        let decoded = loadDecodedHistoryFiles()
        let fingerprint = historyFingerprint(from: decoded, excludingActive: activePaths)
        if let fingerprint, fingerprint == lastRebuildFingerprint {
            return false
        }

        let sessions = decoded.map(\.session)
        lastDecodedHistorySessions = sessions
        let nextRecentProjects = Self.buildRecentProjects(
            from: sessions, excludingActive: activePaths
        )
        lastRebuildFingerprint = fingerprint
        if nextRecentProjects != recentProjects {
            recentProjects = nextRecentProjects
        }
        return true
    }

    /// Pure function: group sessions by project, take most recent per project,
    /// filter active, sort by date, cap at 10.
    static func buildRecentProjects(
        from sessions: [SessionData],
        excludingActive activePaths: Set<String> = [],
        projectPathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [RecentProject] {
        let activeProjectPaths = Set(activePaths.map(canonicalRecentProjectPath))
        var grouped: [String: (latest: SessionData, count: Int, projectPath: String)] = [:]
        for session in sessions {
            if session.isCodex || session.isClaudeDesktopHost { continue }
            let canonicalProjectPath = canonicalRecentProjectPath(session.projectPath)
            if activeProjectPaths.contains(canonicalProjectPath) { continue }
            guard isDurableRecentProjectPath(canonicalProjectPath, projectPathExists: projectPathExists) else {
                continue
            }
            if let existing = grouped[canonicalProjectPath] {
                let newer = session.effectiveEndDate > existing.latest.effectiveEndDate
                grouped[canonicalProjectPath] = (
                    latest: newer ? session : existing.latest,
                    count: existing.count + 1,
                    projectPath: canonicalProjectPath
                )
            } else {
                grouped[canonicalProjectPath] = (latest: session, count: 1, projectPath: canonicalProjectPath)
            }
        }

        return grouped.values
            .sorted { $0.latest.effectiveEndDate > $1.latest.effectiveEndDate }
            .prefix(10)
            .map { entry in
                RecentProject(
                    projectPath: entry.projectPath,
                    projectName: entry.latest.projectName,
                    lastBranch: entry.latest.branch,
                    lastSessionAt: entry.latest.effectiveEndDate,
                    sessionCount: entry.count,
                    lastEditor: RecentProject.projectOpenerName(from: entry.latest.terminal),
                    lastAgent: RecentProject.agentName(from: entry.latest),
                    workspaceFile: entry.latest.workspaceFile
                )
            }
    }

    static func isDurableRecentProjectPath(
        _ path: String,
        projectPathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        let canonicalPath = canonicalRecentProjectPath(path)
        guard !isExcludedRecentProjectPath(canonicalPath) else { return false }
        guard !Config.isLikelyPrivacyProtectedUserPath(canonicalPath) else { return true }
        return projectPathExists(canonicalPath)
    }

    private static func isExcludedRecentProjectPath(_ canonicalPath: String) -> Bool {
        if nonProjectRecentProjectPaths.contains(canonicalPath) { return true }
        return nonDurableRecentProjectRootPaths.contains { root in
            canonicalPath == root || canonicalPath.hasPrefix(root + "/")
        }
    }

    static func canonicalRecentProjectPath(_ path: String) -> String {
        let path = Config.standardizedPath(path)
        guard !Config.isLikelyPrivacyProtectedUserPath(path) else { return path }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static var nonDurableRecentProjectRootPaths: [String] {
        [
            "/tmp",
            "/private/tmp",
            NSTemporaryDirectory(),
            "/var/folders",
            NSHomeDirectory() + "/Library/Caches",
            NSHomeDirectory() + "/.cache",
        ].flatMap(comparableRecentProjectPaths)
    }

    private static var nonProjectRecentProjectPaths: Set<String> {
        Set([
            "/",
            NSHomeDirectory(),
            NSHomeDirectory() + "/projects",
        ].flatMap(comparableRecentProjectPaths))
    }

    private static func comparableRecentProjectPaths(_ path: String) -> [String] {
        let trimmed = path == "/" ? path : (path.hasSuffix("/") ? String(path.dropLast()) : path)
        return Array(Set([trimmed, canonicalRecentProjectPath(trimmed)]))
    }

    // MARK: - Internal (testable)

    func loadDecodedHistoryFiles() -> [(url: URL, session: SessionData)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: historyDir, includingPropertiesForKeys: nil
        ) else {
            logger.warning("loadDecodedHistoryFiles: could not read directory")
            return []
        }
        let jsonFiles = entries.filter {
            $0.pathExtension == "json"
            && !$0.lastPathComponent.hasSuffix(".tmp")
        }
        var decoded: [(url: URL, session: SessionData)] = jsonFiles
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else {
                    logger.warning(
                        "loadDecodedHistoryFiles: could not read \(url.lastPathComponent, privacy: .public)"
                    )
                    return nil
                }
                guard let session = try? JSONDecoder.sessionDecoder
                    .decode(SessionData.self, from: data)
                else {
                    logger.error(
                        "loadDecodedHistoryFiles: decode failed \(url.lastPathComponent, privacy: .public)"
                    )
                    return nil
                }
                return (url, session)
            }
        decoded.sort { $0.session.effectiveEndDate > $1.session.effectiveEndDate }
        return decoded
    }

    func filesToPrune(
        from decoded: [(url: URL, session: SessionData)],
        projectPathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [URL] {
        var seenProjects: Set<String> = []
        var capEligibleKeep: [(url: URL, session: SessionData)] = []
        var toRemove: [URL] = []
        let cutoff = Date().addingTimeInterval(
            TimeInterval(-Self.maxAgeDays * 86400)
        )

        // Keep only the most recent entry per canonical project path. Paths that
        // can never become Recent rows are pruned; currently missing project paths
        // are preserved for restore, but do not count against the durable-project cap.
        for entry in decoded {
            let canonicalPath = Self.canonicalRecentProjectPath(entry.session.projectPath)
            if entry.session.isCodex || entry.session.isClaudeDesktopHost || Self.isExcludedRecentProjectPath(canonicalPath) {
                toRemove.append(entry.url)
            } else if seenProjects.contains(canonicalPath) {
                toRemove.append(entry.url)
            } else if entry.session.effectiveEndDate < cutoff {
                toRemove.append(entry.url)
            } else {
                seenProjects.insert(canonicalPath)
                if Config.isLikelyPrivacyProtectedUserPath(canonicalPath) || projectPathExists(canonicalPath) {
                    capEligibleKeep.append(entry)
                }
            }
        }

        // If still over maxFiles, remove oldest durable project entries.
        if capEligibleKeep.count > Self.maxFiles {
            toRemove.append(contentsOf: capEligibleKeep[Self.maxFiles...].map(\.url))
        }
        return toRemove
    }

    // MARK: - Private

    private func pruneHistory() {
        let decoded = loadDecodedHistoryFiles()
        let toRemove = filesToPrune(from: decoded)
        let fm = FileManager.default
        for url in toRemove {
            try? fm.removeItem(at: url)
            logger.info("pruned history: \(url.lastPathComponent, privacy: .public)")
        }
    }

    private func historyFingerprint(
        from decoded: [(url: URL, session: SessionData)],
        excludingActive activePaths: Set<String>
    ) -> HistoryRebuildFingerprint? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: historyDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else {
            return nil
        }
        let jsonFiles = entries.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".tmp") }
        var files: [HistoryFileFingerprint] = []
        for url in jsonFiles {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                return nil
            }
            files.append(HistoryFileFingerprint(
                path: url.path,
                modificationDate: values.contentModificationDate ?? .distantPast,
                fileSize: values.fileSize ?? -1
            ))
        }
        files.sort { $0.path < $1.path }
        return HistoryRebuildFingerprint(
            files: files,
            activePaths: activePaths,
            projectPaths: recentProjectPathFingerprints(from: decoded.map(\.session))
        )
    }

    private func recentProjectPathFingerprints(from sessions: [SessionData]) -> [HistoryProjectPathFingerprint] {
        var states: [String: Bool] = [:]
        for session in sessions where !session.isCodex && !session.isClaudeDesktopHost {
            let canonicalPath = Self.canonicalRecentProjectPath(session.projectPath)
            if states[canonicalPath] == nil {
                states[canonicalPath] = Self.isDurableRecentProjectPath(canonicalPath)
            }
        }
        return states
            .map { HistoryProjectPathFingerprint(path: $0.key, isDurable: $0.value) }
            .sorted { $0.path < $1.path }
    }

    private func sanitizeFilenameComponent(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_"))
        let filtered = String(name.unicodeScalars.filter {
            allowed.contains($0)
        })
        let result = filtered.isEmpty ? "unknown" : filtered
        return String(result.prefix(50))
    }
}

// MARK: - ISO 8601 archive formatter

private extension ISO8601DateFormatter {
    static let archiveFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()
}

private struct HistoryRebuildFingerprint: Equatable {
    let files: [HistoryFileFingerprint]
    let activePaths: Set<String>
    let projectPaths: [HistoryProjectPathFingerprint]
}

private struct HistoryFileFingerprint: Equatable {
    let path: String
    let modificationDate: Date
    let fileSize: Int
}

private struct HistoryProjectPathFingerprint: Equatable {
    let path: String
    let isDurable: Bool
}
