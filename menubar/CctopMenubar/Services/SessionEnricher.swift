import Foundation

/// Enriches sessions with git branch and session name data in-memory.
/// Runs in the menubar app, replacing lookups previously done in cctop-hook.
/// Skips opencode sessions (they provide their own branch/name via plugin.js).
class SessionEnricher {
    // Cache: projectPath → (branch, timestamp)
    private var branchCache: [String: (branch: String, fetchedAt: Date)] = [:]
    // Cache: sessionId → sessionName (nil value = already looked up, not found)
    private var nameCache: [String: String?] = [:]

    private static let branchMaxAge: TimeInterval = 30

    /// Enrich session with branch and session name (in-memory only).
    func enrich(_ session: inout Session) {
        guard session.source != "opencode" else { return }
        enrichBranch(&session)
        enrichSessionName(&session)
    }

    private func enrichBranch(_ session: inout Session) {
        let path = session.projectPath
        if let cached = branchCache[path],
           -cached.fetchedAt.timeIntervalSinceNow < Self.branchMaxAge {
            session.branch = cached.branch
            return
        }
        let branch = Self.getCurrentBranch(cwd: path)
        branchCache[path] = (branch, Date())
        session.branch = branch
    }

    private func enrichSessionName(_ session: inout Session) {
        let sid = session.sessionId
        if let cached = nameCache[sid] {
            session.sessionName = cached
            return
        }
        guard let transcriptPath = session.transcriptPath else { return }
        let name = SessionNameLookup.lookupSessionName(
            transcriptPath: transcriptPath, sessionId: sid
        )
        nameCache[sid] = name
        session.sessionName = name
    }

    /// Invalidate session name cache so the next enrich() re-reads the transcript.
    func invalidateSessionName(_ sessionId: String) {
        nameCache.removeValue(forKey: sessionId)
    }

    /// Invalidate branch cache so the next enrich() re-runs git.
    func invalidateBranch(projectPath: String) {
        branchCache.removeValue(forKey: projectPath)
    }

    /// Remove cache entries for sessions/projects that are no longer active.
    func pruneCache(
        activeSessionIds: Set<String>,
        activeProjectPaths: Set<String>
    ) {
        nameCache = nameCache.filter { activeSessionIds.contains($0.key) }
        branchCache = branchCache.filter {
            activeProjectPaths.contains($0.key)
        }
    }

    /// Spawn `git branch --show-current` and return the branch name.
    static func getCurrentBranch(cwd: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["branch", "--show-current"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "unknown" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let branch = String(
                data: data, encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return branch.isEmpty ? "unknown" : branch
        } catch {
            return "unknown"
        }
    }
}
