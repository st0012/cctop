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

    init(historyDir: URL = URL(fileURLWithPath: Config.historyDir())) {
        self.historyDir = historyDir
        rebuildRecentProjects()
    }

    // MARK: - Archiving

    /// Archive a dead session to the history directory.
    /// Sets `endedAt`, writes to history, prunes old files, and returns success.
    @discardableResult
    func archiveSession(_ session: Session) -> Bool {
        var archived = session
        archived.endedAt = Date()

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
    func rebuildRecentProjects(
        excludingActive activePaths: Set<String> = []
    ) {
        let sessions = loadDecodedHistoryFiles().map(\.session)
        recentProjects = Self.buildRecentProjects(
            from: sessions, excludingActive: activePaths
        )
    }

    /// Pure function: group sessions by project, take most recent per project,
    /// filter active, sort by date, cap at 10.
    static func buildRecentProjects(
        from sessions: [Session],
        excludingActive activePaths: Set<String> = []
    ) -> [RecentProject] {
        var grouped: [String: (latest: Session, count: Int)] = [:]
        for session in sessions {
            if let existing = grouped[session.projectPath] {
                let newer = session.effectiveEndDate > existing.latest.effectiveEndDate
                grouped[session.projectPath] = (
                    latest: newer ? session : existing.latest,
                    count: existing.count + 1
                )
            } else {
                grouped[session.projectPath] = (latest: session, count: 1)
            }
        }

        return grouped.values
            .filter { !activePaths.contains($0.latest.projectPath) }
            .sorted { $0.latest.effectiveEndDate > $1.latest.effectiveEndDate }
            .prefix(10)
            .map { entry in
                RecentProject(
                    projectPath: entry.latest.projectPath,
                    projectName: entry.latest.projectName,
                    lastBranch: entry.latest.branch,
                    lastSessionAt: entry.latest.effectiveEndDate,
                    sessionCount: entry.count,
                    lastEditor: entry.latest.terminal?.program,
                    workspaceFile: entry.latest.workspaceFile
                )
            }
    }

    // MARK: - Internal (testable)

    func loadDecodedHistoryFiles() -> [(url: URL, session: Session)] {
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
        var decoded: [(url: URL, session: Session)] = jsonFiles
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else {
                    logger.warning(
                        "loadDecodedHistoryFiles: could not read \(url.lastPathComponent, privacy: .public)"
                    )
                    return nil
                }
                guard let session = try? JSONDecoder.sessionDecoder
                    .decode(Session.self, from: data)
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
        from decoded: [(url: URL, session: Session)]
    ) -> [URL] {
        var seenProjects: Set<String> = []
        var toKeep: [(url: URL, session: Session)] = []
        var toRemove: [URL] = []

        // Keep only the most recent entry per project
        for entry in decoded {
            if seenProjects.contains(entry.session.projectPath) {
                toRemove.append(entry.url)
            } else {
                seenProjects.insert(entry.session.projectPath)
                toKeep.append(entry)
            }
        }

        // Remove entries older than maxAgeDays
        let cutoff = Date().addingTimeInterval(
            TimeInterval(-Self.maxAgeDays * 86400)
        )
        var finalKeep: [(url: URL, session: Session)] = []
        for entry in toKeep {
            if entry.session.effectiveEndDate < cutoff {
                toRemove.append(entry.url)
            } else {
                finalKeep.append(entry)
            }
        }

        // If still over maxFiles, remove oldest
        if finalKeep.count > Self.maxFiles {
            toRemove.append(contentsOf: finalKeep[Self.maxFiles...].map(\.url))
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
