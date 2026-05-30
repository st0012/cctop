import XCTest
@testable import CctopMenubar

final class SessionFileFormatTests: XCTestCase {
    private func writeCodexStateDatabase(path: String, archivedThreads: Set<String>) throws {
        let archivedRows = archivedThreads.map {
            """
            INSERT INTO threads (id, archived) VALUES ('\($0)', 1);
            """
        }.joined(separator: "\n")
        let sql = """
        DROP TABLE IF EXISTS threads;
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            archived INTEGER NOT NULL DEFAULT 0
        );
        \(archivedRows)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path]
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data(sql.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func codexDesktopSession(sessionId: String, projectPath: String) -> Session {
        var session = Session(
            sessionId: sessionId,
            projectPath: projectPath,
            branch: "main",
            terminal: TerminalInfo(bundleId: "com.openai.codex")
        )
        session.source = Session.codexSource
        session.pid = UInt32(ProcessInfo.processInfo.processIdentifier)
        session.status = .waitingInput
        return session
    }

    private func claudeDesktopSession(sessionId: String, projectPath: String) -> Session {
        var session = Session(
            sessionId: sessionId,
            projectPath: projectPath,
            branch: "main",
            terminal: TerminalInfo(bundleId: HostAppBundleID.claudeDesktop)
        )
        session.source = "cc"
        session.pid = UInt32(ProcessInfo.processInfo.processIdentifier)
        session.status = .waitingInput
        return session
    }

    private func writeClaudeDesktopSessionMetadata(
        root: String,
        cliSessionId: String,
        isArchived: Bool,
        lastActivityAt: Any? = nil
    ) throws {
        let sessionDir = (root as NSString).appendingPathComponent("account/project")
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let metadataPath = (sessionDir as NSString)
            .appendingPathComponent("local_\(UUID().uuidString).json")
        var payload: [String: Any] = [
            "sessionId": "local_\(UUID().uuidString)",
            "cliSessionId": cliSessionId,
            "isArchived": isArchived,
            "title": "Archived Claude Session"
        ]
        if let lastActivityAt {
            payload["lastActivityAt"] = lastActivityAt
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: URL(fileURLWithPath: metadataPath))
    }

    private func codexTitleGenerationPrompt(for userPrompt: String = "Why do I have several memories sessions?") -> String {
        """
        You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title for a task that will be created from that prompt.
        The tasks typically have to do with coding-related tasks, for example requests for bug fixes or questions about a codebase. The title you generate will be shown in the UI to represent the prompt.
        Generate a concise UI title (up to 36 characters) for this task.
        Fill the structured title field with plain text.

        User prompt:
        \(userPrompt)
        """
    }

    func testLegacyUUIDFilenameClassification() {
        // Pre-PID files were keyed by a bare session UUID → should be removed.
        XCTAssertTrue(SessionManager.isLegacyUUIDFilename("019e4b0c-9473-7a33-a4b9-749fd2c83a9e"))
        // PID-keyed files are numeric → keep.
        XCTAssertFalse(SessionManager.isLegacyUUIDFilename("31349"))
        // Codex per-conversation files → keep.
        XCTAssertFalse(SessionManager.isLegacyUUIDFilename("codex-019e4b0c-9473-7a33-a4b9-749fd2c83a9e"))
    }

    // MARK: - Shared-PID identity

    /// Codex multiplexes every conversation onto one host PID, so identifying a session
    /// by PID collapses them. Two Codex conversations sharing a host PID must get
    /// distinct ids (by session_id); non-codex sources keep PID-based identity.
    func testCodexSessionsWithSharedPIDHaveDistinctIDs() {
        var a = Session(sessionId: "conv-a", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        a.source = "codex"; a.pid = 31349
        var b = Session(sessionId: "conv-b", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        b.source = "codex"; b.pid = 31349

        XCTAssertEqual(a.id, "conv-a")
        XCTAssertEqual(b.id, "conv-b")
        XCTAssertNotEqual(a.id, b.id)

        // Non-codex still identified by PID.
        var cc = Session(sessionId: "conv-c", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        cc.source = "cc"; cc.pid = 31349
        XCTAssertEqual(cc.id, "31349")
    }

    /// A transient migration window can leave two files for the same conversation (the old
    /// PID-keyed file plus the new codex-<id> file), so the loaded list can contain two
    /// sessions with the same id. dedupedByID must collapse them (keeping the freshest)
    /// so nothing keyed by id — SwiftUI identity, the status map — ever sees a duplicate.
    func testDedupedByIDCollapsesDuplicateIDsKeepingFreshest() {
        var old = Session(sessionId: "conv-a", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        old.source = "codex"; old.pid = 31349
        old.sessionName = "stale"
        old.lastActivity = Date(timeIntervalSinceNow: -120)

        var fresh = Session(sessionId: "conv-a", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        fresh.source = "codex"; fresh.pid = 31349
        fresh.sessionName = "current"
        fresh.lastActivity = Date()

        var other = Session(sessionId: "conv-b", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        other.source = "codex"; other.pid = 31349

        let result = SessionIdentityPolicy.dedupedByDisplayID([old, fresh, other])
        // Two distinct ids survive; the duplicate id keeps the most recently active entry.
        XCTAssertEqual(result.map(\.id).sorted(), ["conv-a", "conv-b"])
        XCTAssertEqual(result.first { $0.id == "conv-a" }?.sessionName, "current")
    }

    // MARK: - Codex memory maintenance sessions

    func testCodexMemoryMaintenanceSessionUsesConfiguredDirectory() {
        let root = NSTemporaryDirectory() + "cctop-memory-\(UUID().uuidString)"
        let memoriesDir = (root as NSString).appendingPathComponent("alice/.codex/memories")
        setenv("CCTOP_CODEX_MEMORIES_DIR", memoriesDir + "/", 1)
        defer {
            unsetenv("CCTOP_CODEX_MEMORIES_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let normalizedEquivalent = (root as NSString)
            .appendingPathComponent("alice/.codex/../.codex/memories")
        let session = codexDesktopSession(sessionId: "codex-memory", projectPath: normalizedEquivalent)

        XCTAssertEqual(Config.codexMemoriesDir(), memoriesDir + "/")
        XCTAssertTrue(session.isCodexMemoryMaintenanceSession)
    }

    func testCodexMemoryMaintenanceClassificationIsNarrow() {
        let root = NSTemporaryDirectory() + "cctop-memory-\(UUID().uuidString)"
        let memoriesDir = (root as NSString).appendingPathComponent("bob/.codex/memories")
        setenv("CCTOP_CODEX_MEMORIES_DIR", memoriesDir, 1)
        defer {
            unsetenv("CCTOP_CODEX_MEMORIES_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let normalProject = codexDesktopSession(
            sessionId: "normal-codex",
            projectPath: (root as NSString).appendingPathComponent("bob/projects/cctop")
        )
        XCTAssertFalse(normalProject.isCodexMemoryMaintenanceSession)

        var nonDesktopMemory = Session(
            sessionId: "codex-cli-memory",
            projectPath: memoriesDir,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        nonDesktopMemory.source = Session.codexSource
        XCTAssertFalse(nonDesktopMemory.isCodexMemoryMaintenanceSession)

        var nonCodexMemory = codexDesktopSession(sessionId: "other-memory", projectPath: memoriesDir)
        nonCodexMemory.source = "cc"
        XCTAssertFalse(nonCodexMemory.isCodexMemoryMaintenanceSession)

        XCTAssertEqual(normalProject.projectName, "cctop")
    }

    func testCodexDesktopTitleGenerationClassificationIsNarrow() {
        let projectPath = "/Users/alice/projects/cctop"

        var titleGeneration = codexDesktopSession(sessionId: "title-helper", projectPath: projectPath)
        titleGeneration.lastPrompt = codexTitleGenerationPrompt()
        XCTAssertTrue(titleGeneration.isCodexDesktopTitleGenerationSession)

        var normalCodexDesktop = codexDesktopSession(sessionId: "normal-codex", projectPath: projectPath)
        normalCodexDesktop.sessionName = "Explain Codex memory sessions"
        normalCodexDesktop.lastPrompt = "They disappeared indeed. commit."
        XCTAssertFalse(normalCodexDesktop.isCodexDesktopTitleGenerationSession)

        var namedTitleGeneration = titleGeneration
        namedTitleGeneration.sessionName = "Generated title"
        XCTAssertFalse(namedTitleGeneration.isCodexDesktopTitleGenerationSession)

        var nonDesktopTitleGeneration = Session(
            sessionId: "terminal-title-helper",
            projectPath: projectPath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        nonDesktopTitleGeneration.source = Session.codexSource
        nonDesktopTitleGeneration.lastPrompt = codexTitleGenerationPrompt()
        XCTAssertFalse(nonDesktopTitleGeneration.isCodexDesktopTitleGenerationSession)

        var nonCodexTitleGeneration = titleGeneration
        nonCodexTitleGeneration.source = "cc"
        XCTAssertFalse(nonCodexTitleGeneration.isCodexDesktopTitleGenerationSession)
    }

    @MainActor
    func testSessionManagerHidesCodexMemoryMaintenanceSessionsWithoutRemovingFiles() throws {
        let root = NSTemporaryDirectory() + "cctop-memory-cleanup-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let memoriesDir = (root as NSString).appendingPathComponent("carol/.codex/memories")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        setenv("CCTOP_SESSIONS_DIR", sessionsDir, 1)
        setenv("CCTOP_CODEX_MEMORIES_DIR", memoriesDir, 1)
        defer {
            unsetenv("CCTOP_SESSIONS_DIR")
            unsetenv("CCTOP_CODEX_MEMORIES_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let memorySession = codexDesktopSession(sessionId: "memory-session", projectPath: memoriesDir)
        let memoryPath = (sessionsDir as NSString).appendingPathComponent("codex-memory-session.json")
        try memorySession.writeToFile(path: memoryPath)
        FileManager.default.createFile(atPath: memoryPath + ".lock", contents: nil)

        var manager: SessionManager? = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir))
        )
        manager?.loadSessions()

        XCTAssertEqual(manager?.sessions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: memoryPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: memoryPath + ".lock"))
        XCTAssertTrue(try Session.fromFile(path: memoryPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)

        manager = nil
    }

    @MainActor
    func testSessionManagerHidesCodexDesktopTitleGenerationSessionsWithoutRemovingFiles() throws {
        let root = NSTemporaryDirectory() + "cctop-title-helper-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        setenv("CCTOP_SESSIONS_DIR", sessionsDir, 1)
        defer {
            unsetenv("CCTOP_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        var titleGeneration = codexDesktopSession(
            sessionId: "title-helper",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        )
        titleGeneration.lastPrompt = codexTitleGenerationPrompt(for: "Why do I have several memories sessions?")
        let titleHelperPath = (sessionsDir as NSString).appendingPathComponent("codex-title-helper.json")
        try titleGeneration.writeToFile(path: titleHelperPath)
        FileManager.default.createFile(atPath: titleHelperPath + ".lock", contents: nil)

        var manager: SessionManager? = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir))
        )
        manager?.loadSessions()

        XCTAssertEqual(manager?.sessions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: titleHelperPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: titleHelperPath + ".lock"))
        XCTAssertTrue(try Session.fromFile(path: titleHelperPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)

        manager = nil
    }

    func testAutoHiddenSessionSnapshotPreservesLatestFileFields() throws {
        let root = NSTemporaryDirectory() + "cctop-auto-hide-merge-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let memoriesDir = (root as NSString).appendingPathComponent("carol/.codex/memories")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)

        setenv("CCTOP_CODEX_MEMORIES_DIR", memoriesDir, 1)
        defer {
            unsetenv("CCTOP_CODEX_MEMORIES_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        var latest = codexDesktopSession(sessionId: "memory-session", projectPath: memoriesDir)
        latest.status = .working
        latest.lastTool = "Read"
        latest.lastToolDetail = "Sources.swift"
        latest.lastPrompt = "Summarize project state"
        latest.activeSubagents = [
            SubagentInfo(agentId: "agent-1", agentType: "reviewer", startedAt: Date(timeIntervalSince1970: 100))
        ]

        let memoryPath = (sessionsDir as NSString).appendingPathComponent("codex-memory-session.json")
        try latest.writeToFile(path: memoryPath)

        let hidden = try XCTUnwrap(SessionManager.autoHiddenSessionSnapshot(path: memoryPath))

        XCTAssertTrue(hidden.hidden)
        XCTAssertEqual(hidden.status, .working)
        XCTAssertEqual(hidden.lastTool, "Read")
        XCTAssertEqual(hidden.lastToolDetail, "Sources.swift")
        XCTAssertEqual(hidden.lastPrompt, "Summarize project state")
        XCTAssertEqual(hidden.activeSubagents, latest.activeSubagents)
    }

    func testAutoHiddenSessionSnapshotSkipsFilesThatNoLongerNeedHiding() throws {
        let root = NSTemporaryDirectory() + "cctop-auto-hide-skip-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let normalSession = codexDesktopSession(
            sessionId: "normal-codex",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        )
        let path = (sessionsDir as NSString).appendingPathComponent("codex-normal.json")
        try normalSession.writeToFile(path: path)

        XCTAssertNil(try SessionManager.autoHiddenSessionSnapshot(path: path))
    }

    @MainActor
    func testSessionManagerSkipsAlreadyHiddenSessionsWithoutArchivingOrRemovingThem() throws {
        let root = NSTemporaryDirectory() + "cctop-hidden-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        setenv("CCTOP_SESSIONS_DIR", sessionsDir, 1)
        defer {
            unsetenv("CCTOP_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        var hidden = Session(
            sessionId: "hidden-review",
            projectPath: (root as NSString).appendingPathComponent("reviews/cctop"),
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        hidden.hidden = true
        hidden.pid = 999_999
        let hiddenPath = (sessionsDir as NSString).appendingPathComponent("999999.json")
        try hidden.writeToFile(path: hiddenPath)

        var manager: SessionManager? = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir))
        )
        manager?.loadSessions()

        XCTAssertEqual(manager?.sessions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenPath))
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)

        manager = nil
    }

    // MARK: - Desktop dedup by session_id (Phase 1, total order)

    private static let desktopBundle = "com.anthropic.claudefordesktop"

    private func candidate(
        sessionId: String, pid: UInt32, bundleId: String?, lifecycleRank: Int,
        source: String? = nil,
        lastActivity: Date = Date(timeIntervalSince1970: 1000),
        endedAt: Date? = nil, disconnectedAt: Date? = nil, mtime: Date = .distantPast, path: String = "/x.json"
    ) -> DedupCandidate {
        var s = Session(sessionId: sessionId, projectPath: "/tmp/p", branch: "main",
                        terminal: TerminalInfo(bundleId: bundleId))
        s.pid = pid
        s.source = source
        s.lastActivity = lastActivity
        s.endedAt = endedAt
        s.disconnectedAt = disconnectedAt
        return DedupCandidate(session: s, lifecycleRank: lifecycleRank, mtime: mtime, path: path)
    }

    private func deduped(_ candidates: [DedupCandidate]) -> [Session] {
        SessionIdentityPolicy.dedupedCandidatesByStableKey(candidates).map(\.session)
    }

    func testDedupDesktopCollapsesSameSessionIdDifferentPid() {
        let dead = candidate(sessionId: "conv-a", pid: 100, bundleId: Self.desktopBundle, lifecycleRank: 1)
        let live = candidate(sessionId: "conv-a", pid: 200, bundleId: Self.desktopBundle, lifecycleRank: 0)
        let result = deduped([dead, live])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.pid, 200) // live (rank 0) wins, NOT the dead/newer-file one
    }

    func testDedupLiveBeatsDormantEvenIfDormantNewer() {
        let dormantNewer = candidate(sessionId: "c", pid: 1, bundleId: Self.desktopBundle,
                                     lifecycleRank: 1, lastActivity: Date(timeIntervalSince1970: 9999))
        let liveOlder = candidate(sessionId: "c", pid: 2, bundleId: Self.desktopBundle,
                                  lifecycleRank: 0, lastActivity: Date(timeIntervalSince1970: 1))
        let result = deduped([dormantNewer, liveOlder])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.pid, 2) // lifecycle rank dominates lastActivity
    }

    func testDedupDormantBeatsFinished() {
        let finished = candidate(sessionId: "c", pid: 1, bundleId: Self.desktopBundle, lifecycleRank: 2)
        let dormant = candidate(sessionId: "c", pid: 2, bundleId: Self.desktopBundle, lifecycleRank: 1)
        XCTAssertEqual(deduped([finished, dormant]).first?.pid, 2)
    }

    func testDedupSameRankNewerLastActivityWins() {
        let older = candidate(sessionId: "c", pid: 1, bundleId: Self.desktopBundle,
                              lifecycleRank: 1, lastActivity: Date(timeIntervalSince1970: 1))
        let newer = candidate(sessionId: "c", pid: 2, bundleId: Self.desktopBundle,
                              lifecycleRank: 1, lastActivity: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(deduped([older, newer]).first?.pid, 2)
    }

    func testDedupTieBreaksByEffectiveEndDate() {
        let t = Date(timeIntervalSince1970: 5)
        let a = candidate(sessionId: "c", pid: 1, bundleId: Self.desktopBundle,
                          lifecycleRank: 1, lastActivity: t, endedAt: Date(timeIntervalSince1970: 10))
        let b = candidate(sessionId: "c", pid: 2, bundleId: Self.desktopBundle,
                          lifecycleRank: 1, lastActivity: t, endedAt: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(deduped([a, b]).first?.pid, 2) // newer effectiveEndDate
    }

    func testDedupFinalTieBreakByPathIsDeterministic() {
        let t = Date(timeIntervalSince1970: 5)
        let a = candidate(sessionId: "c", pid: 1, bundleId: Self.desktopBundle,
                          lifecycleRank: 1, lastActivity: t, mtime: t, path: "/a.json")
        let b = candidate(sessionId: "c", pid: 2, bundleId: Self.desktopBundle,
                          lifecycleRank: 1, lastActivity: t, mtime: t, path: "/b.json")
        // Smaller path wins, regardless of input order (total, stable).
        XCTAssertEqual(deduped([b, a]).first?.pid, 1)
        XCTAssertEqual(deduped([a, b]).first?.pid, 1)
    }

    func testDedupMissingMtimeLosesToRealMtime() {
        let t = Date(timeIntervalSince1970: 5)
        let noMtime = candidate(sessionId: "c", pid: 1, bundleId: Self.desktopBundle,
                                lifecycleRank: 1, lastActivity: t, mtime: .distantPast)
        let realMtime = candidate(sessionId: "c", pid: 2, bundleId: Self.desktopBundle,
                                  lifecycleRank: 1, lastActivity: t, mtime: t)
        XCTAssertEqual(deduped([noMtime, realMtime]).first?.pid, 2)
    }

    func testDedupTerminalKeepsPidIdentityEvenWithSameSessionId() {
        let oldPid = candidate(sessionId: "shared", pid: 100, bundleId: "com.googlecode.iterm2", lifecycleRank: 0)
        let newPid = candidate(sessionId: "shared", pid: 200, bundleId: "com.googlecode.iterm2", lifecycleRank: 0)
        let result = deduped([oldPid, newPid])
        XCTAssertEqual(result.compactMap(\.pid).sorted(), [100, 200])
    }

    func testDedupUnknownHostKeepsPidIdentityEvenWithSameSessionId() {
        let oldPid = candidate(sessionId: "shared", pid: 100, bundleId: nil, lifecycleRank: 0)
        let newPid = candidate(sessionId: "shared", pid: 200, bundleId: nil, lifecycleRank: 0)
        let result = deduped([oldPid, newPid])
        XCTAssertEqual(result.compactMap(\.pid).sorted(), [100, 200])
    }

    func testDedupMigratedCodexSessionUsesStableConversationIdAcrossHostClass() {
        let oldPidKeyed = candidate(
            sessionId: "conv-a", pid: 100, bundleId: nil, lifecycleRank: 2,
            source: Session.codexSource, path: "/100.json"
        )
        let desktopKeyed = candidate(
            sessionId: "conv-a", pid: 200, bundleId: HostAppBundleID.codexDesktop,
            lifecycleRank: 0, source: Session.codexSource, path: "/codex-conv-a.json"
        )

        let result = deduped([oldPidKeyed, desktopKeyed])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.pid, 200)
    }

    @MainActor
    func testSessionManagerRemovesFinishedCodexDedupLoserWithoutArchiving() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-dedup-cleanup-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        setenv("CCTOP_SESSIONS_DIR", sessionsDir, 1)
        defer {
            unsetenv("CCTOP_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        var oldPidKeyed = Session(
            sessionId: "conv-a", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo()
        )
        oldPidKeyed.source = Session.codexSource
        oldPidKeyed.pid = 999_999
        oldPidKeyed.endedAt = Date(timeIntervalSince1970: 100)
        let oldPath = (sessionsDir as NSString).appendingPathComponent("999999.json")
        try oldPidKeyed.writeToFile(path: oldPath)

        var desktopKeyed = Session(
            sessionId: "conv-a", projectPath: "/tmp/p", branch: "main",
            terminal: TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        )
        desktopKeyed.source = Session.codexSource
        desktopKeyed.lastActivity = Date()
        let desktopPath = (sessionsDir as NSString).appendingPathComponent("codex-conv-a.json")
        try desktopKeyed.writeToFile(path: desktopPath)

        var manager: SessionManager? = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir))
        )
        manager?.loadSessions()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: desktopPath))
        XCTAssertEqual(manager?.sessions.map(\.sessionId), ["conv-a"])
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)

        manager = nil
    }

    @MainActor
    func testSessionManagerHidesArchivedCodexDesktopSessionButKeepsFileForUnarchive() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-archived-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: ["archived-thread"])

        setenv("CCTOP_SESSIONS_DIR", sessionsDir, 1)
        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_SESSIONS_DIR")
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-archived-thread.json")
        var session = codexDesktopSession(sessionId: "archived-thread", projectPath: "/tmp/p")
        session.lastActivity = Date()
        try session.writeToFile(path: sessionPath)

        var manager: SessionManager? = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir))
        )
        manager?.loadSessions()

        XCTAssertEqual(manager?.sessions.map(\.sessionId), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)

        try writeCodexStateDatabase(path: stateDB, archivedThreads: [])
        manager?.loadSessions()

        XCTAssertEqual(manager?.sessions.map(\.sessionId), ["archived-thread"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))

        manager = nil
    }

    @MainActor
    func testSessionManagerHidesArchivedCodexDesktopSessionWhenSourceIsMissing() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-archived-missing-source-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: ["archived-without-source"])

        setenv("CCTOP_SESSIONS_DIR", sessionsDir, 1)
        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_SESSIONS_DIR")
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-archived-without-source.json")
        var session = codexDesktopSession(sessionId: "archived-without-source", projectPath: "/tmp/p")
        session.source = nil
        session.lastActivity = Date()
        try session.writeToFile(path: sessionPath)

        var manager: SessionManager? = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir))
        )
        manager?.loadSessions()

        XCTAssertEqual(manager?.sessions.map(\.sessionId), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)

        try writeCodexStateDatabase(path: stateDB, archivedThreads: [])
        manager?.loadSessions()

        XCTAssertEqual(manager?.sessions.map(\.sessionId), ["archived-without-source"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))

        manager = nil
    }

    @MainActor
    func testSessionManagerHidesArchivedClaudeDesktopSessionButKeepsFileForUnarchive() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-archived-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "archived-claude-session",
            isArchived: true
        )

        setenv("CCTOP_SESSIONS_DIR", sessionsDir, 1)
        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", claudeDir, 1)
        defer {
            unsetenv("CCTOP_SESSIONS_DIR")
            unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("archived-claude-session.json")
        var session = claudeDesktopSession(sessionId: "archived-claude-session", projectPath: "/tmp/p")
        session.lastActivity = Date()
        try session.writeToFile(path: sessionPath)

        var manager: SessionManager? = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir))
        )
        manager?.loadSessions()

        XCTAssertEqual(manager?.sessions.map(\.sessionId), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)

        try FileManager.default.removeItem(atPath: claudeDir)
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "archived-claude-session",
            isArchived: false
        )
        manager?.loadSessions()

        XCTAssertEqual(manager?.sessions.map(\.sessionId), ["archived-claude-session"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))

        manager = nil
    }

    @MainActor
    func testSessionManagerHidesArchivedClaudeDesktopSessionWhenSourceIsMissing() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-archived-missing-source-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "archived-claude-without-source",
            isArchived: true
        )

        setenv("CCTOP_SESSIONS_DIR", sessionsDir, 1)
        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", claudeDir, 1)
        defer {
            unsetenv("CCTOP_SESSIONS_DIR")
            unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("archived-claude-without-source.json")
        var session = claudeDesktopSession(sessionId: "archived-claude-without-source", projectPath: "/tmp/p")
        session.source = nil
        session.lastActivity = Date()
        try session.writeToFile(path: sessionPath)

        var manager: SessionManager? = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir))
        )
        manager?.loadSessions()

        XCTAssertEqual(manager?.sessions.map(\.sessionId), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)

        manager = nil
    }

    @MainActor
    func testSessionManagerHidesEndedClaudeDesktopSessionWithoutMatchingMetadata() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-orphan-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "different-claude-session",
            isArchived: false
        )

        setenv("CCTOP_SESSIONS_DIR", sessionsDir, 1)
        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", claudeDir, 1)
        defer {
            unsetenv("CCTOP_SESSIONS_DIR")
            unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("orphan-claude-session.json")
        var session = claudeDesktopSession(sessionId: "orphan-claude-session", projectPath: "/tmp/p")
        let ended = Date()
        session.source = nil
        session.pid = nil
        session.endedAt = ended
        session.disconnectedAt = ended
        try session.writeToFile(path: sessionPath)

        var manager: SessionManager? = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir))
        )
        manager?.loadSessions()

        XCTAssertEqual(manager?.sessions.map(\.sessionId), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)

        manager = nil
    }

    // The GC deletion decision must read live Codex archive state on every call, not a snapshot,
    // so a thread archived between a GC scan and its delete keeps its file. Calling the helper
    // twice across a DB change proves it never caches.
    func testIsCodexDesktopThreadArchivedReadsLiveState() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-archived-live-\(UUID().uuidString)"
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let session = codexDesktopSession(sessionId: "live-thread", projectPath: "/tmp/p")

        try writeCodexStateDatabase(path: stateDB, archivedThreads: ["live-thread"])
        XCTAssertTrue(SessionManager.isCodexDesktopThreadArchived(session))

        try writeCodexStateDatabase(path: stateDB, archivedThreads: [])
        XCTAssertFalse(SessionManager.isCodexDesktopThreadArchived(session))
    }

    // The archive check is gated on the Codex Desktop bundle ID, so a non-Codex-Desktop session
    // sharing an archived thread ID is never treated as archived (and stays on the normal GC path).
    func testIsCodexDesktopThreadArchivedIgnoresNonCodexDesktopHosts() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-archived-host-\(UUID().uuidString)"
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: ["shared-id"])
        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        // A real terminal host (iTerm) running Codex CLI, whose session_id collides with an
        // archived Desktop thread id: it must NOT be treated as archived, because the gate keys on
        // the Codex Desktop bundle id — not on source, and not on a bare nil bundle id that would
        // short-circuit before the lookup even runs.
        var terminalSession = Session(
            sessionId: "shared-id", projectPath: "/tmp/p", branch: "main",
            terminal: TerminalInfo(bundleId: "com.googlecode.iterm2")
        )
        terminalSession.source = Session.codexSource
        XCTAssertFalse(SessionManager.isCodexDesktopThreadArchived(terminalSession))
    }

    // The Claude archive check is also gated on the Claude Desktop bundle ID. A terminal Claude
    // Code session sharing an archived Desktop cliSessionId must stay on the normal lifecycle path.
    func testIsClaudeDesktopSessionArchivedIgnoresNonClaudeDesktopHosts() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-archived-host-\(UUID().uuidString)"
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try writeClaudeDesktopSessionMetadata(root: claudeDir, cliSessionId: "shared-id", isArchived: true)
        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", claudeDir, 1)
        defer {
            unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        var terminalSession = Session(
            sessionId: "shared-id", projectPath: "/tmp/p", branch: "main",
            terminal: TerminalInfo(bundleId: "com.googlecode.iterm2")
        )
        terminalSession.source = "cc"
        XCTAssertFalse(SessionManager.isClaudeDesktopSessionArchived(terminalSession))
    }

    // GC keeps a finished Codex Desktop file while its thread is archived, then reaps it once the
    // thread is unarchived — proving GC consults live archive state at the deletion decision.
    @MainActor
    func testGarbageCollectRespectsLiveCodexArchiveState() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-archived-gc-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        setenv("CCTOP_SESSIONS_DIR", sessionsDir, 1)
        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_SESSIONS_DIR")
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        // Aged past the dormant retention window → finished lifecycle, so GC would normally reap it.
        let old = Date(timeIntervalSinceNow: -SessionManager.lifecycleWindows.retention - 86_400)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-finished-thread.json")
        var session = codexDesktopSession(sessionId: "finished-thread", projectPath: "/tmp/p")
        session.lastActivity = old
        session.disconnectedAt = old
        try session.writeToFile(path: sessionPath)

        var manager: SessionManager? = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            desktopAppConnectionLookup: DesktopAppConnectionLookup { _ in false }
        )

        try writeCodexStateDatabase(path: stateDB, archivedThreads: ["finished-thread"])
        manager?.garbageCollectFinished()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))

        try writeCodexStateDatabase(path: stateDB, archivedThreads: [])
        manager?.garbageCollectFinished()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPath))

        manager = nil
    }

    // GC keeps a finished Claude Desktop file while its session metadata is archived, then reaps
    // it once the session is unarchived.
    @MainActor
    func testGarbageCollectRespectsLiveClaudeArchiveState() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-archived-gc-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        setenv("CCTOP_SESSIONS_DIR", sessionsDir, 1)
        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", claudeDir, 1)
        defer {
            unsetenv("CCTOP_SESSIONS_DIR")
            unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let old = Date(timeIntervalSinceNow: -SessionManager.lifecycleWindows.retention - 86_400)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("finished-claude-session.json")
        var session = claudeDesktopSession(sessionId: "finished-claude-session", projectPath: "/tmp/p")
        session.lastActivity = old
        session.disconnectedAt = old
        try session.writeToFile(path: sessionPath)

        var manager: SessionManager? = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            desktopAppConnectionLookup: DesktopAppConnectionLookup { _ in false }
        )

        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "finished-claude-session",
            isArchived: true
        )
        manager?.garbageCollectFinished()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))

        try FileManager.default.removeItem(atPath: claudeDir)
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "finished-claude-session",
            isArchived: false
        )
        manager?.garbageCollectFinished()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPath))

        manager = nil
    }

    // A missing DB means "no Codex state ⇒ nothing archived" → empty set (deletable). A DB that
    // exists but cannot be parsed means "unknown" → nil, which the GC path must treat as keep.
    func testArchivedThreadIDsDistinguishesMissingFromUnreadable() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-lookup-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let missing = (root as NSString).appendingPathComponent("missing.sqlite")
        XCTAssertEqual(CodexThreadArchiveLookup(stateDatabasePath: missing).archivedThreadIDs(matching: ["x"]), [])

        let corrupt = (root as NSString).appendingPathComponent("corrupt.sqlite")
        try Data("this is not a sqlite database".utf8).write(to: URL(fileURLWithPath: corrupt))
        XCTAssertNil(CodexThreadArchiveLookup(stateDatabasePath: corrupt).archivedThreadIDs(matching: ["x"]))
    }

    func testArchivedClaudeSessionIDsDistinguishesMissingFromUnreadable() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-lookup-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let missing = (root as NSString).appendingPathComponent("missing")
        XCTAssertEqual(
            ClaudeDesktopSessionArchiveLookup(sessionsDirectory: missing).archivedSessionIDs(matching: ["x"]),
            []
        )

        let corruptDir = (root as NSString).appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(atPath: corruptDir, withIntermediateDirectories: true)
        let corrupt = (corruptDir as NSString).appendingPathComponent("local_corrupt.json")
        try Data(#"{"cliSessionId":"x","isArchived":"not-a-boolean"}"#.utf8)
            .write(to: URL(fileURLWithPath: corrupt))
        XCTAssertNil(
            ClaudeDesktopSessionArchiveLookup(sessionsDirectory: corruptDir)
                .archivedSessionIDs(matching: ["x"])
        )
    }

    func testArchivedClaudeSessionIDsAcceptsNumericTimestamps() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-numeric-lookup-\(UUID().uuidString)"
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "numeric-timestamp-session",
            isArchived: true,
            lastActivityAt: 1_779_281_104_333
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        XCTAssertEqual(
            ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir)
                .archivedSessionIDs(matching: ["numeric-timestamp-session"]),
            ["numeric-timestamp-session"]
        )
    }

    func testArchivedClaudeSessionIDsUsesNewestNumericTimestamp() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-numeric-order-\(UUID().uuidString)"
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "numeric-order-session",
            isArchived: false,
            lastActivityAt: 99
        )
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "numeric-order-session",
            isArchived: true,
            lastActivityAt: 1_000
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        XCTAssertEqual(
            ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir)
                .archivedSessionIDs(matching: ["numeric-order-session"]),
            ["numeric-order-session"]
        )
    }

    // Blocker #1: when the archive DB exists but cannot be read, GC must NOT delete a finished
    // Codex Desktop file — failing open here would permanently destroy a session the user archived.
    @MainActor
    func testGarbageCollectKeepsFinishedCodexDesktopFileWhenArchiveDbUnreadable() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-gc-unreadable-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        setenv("CCTOP_SESSIONS_DIR", sessionsDir, 1)
        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_SESSIONS_DIR")
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        // Aged past retention → finished lifecycle, so GC would reap it absent the archive guard.
        let old = Date(timeIntervalSinceNow: -SessionManager.lifecycleWindows.retention - 86_400)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-finished-thread.json")
        var session = codexDesktopSession(sessionId: "finished-thread", projectPath: "/tmp/p")
        session.lastActivity = old
        session.disconnectedAt = old
        try session.writeToFile(path: sessionPath)

        // DB present but unparseable → lookup returns nil → GC fails safe and keeps the file.
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: stateDB))
        var manager: SessionManager? = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            desktopAppConnectionLookup: DesktopAppConnectionLookup { _ in false }
        )
        manager?.garbageCollectFinished()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))

        // Once the DB is readable and shows the thread is not archived, GC reaps it. (Remove the
        // corrupt bytes first — sqlite3 cannot DROP/CREATE over a non-database file.)
        try FileManager.default.removeItem(atPath: stateDB)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: [])
        manager?.garbageCollectFinished()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPath))

        manager = nil
    }

    // Distinct conversations never collapse.
    func testDedupDifferentSessionIdsStaySeparate() {
        let one = candidate(sessionId: "conv-1", pid: 1, bundleId: Self.desktopBundle, lifecycleRank: 0)
        let two = candidate(sessionId: "conv-2", pid: 2, bundleId: Self.desktopBundle, lifecycleRank: 0)
        XCTAssertEqual(deduped([one, two]).count, 2)
    }

    // MARK: - Lifecycle derivation (Phase 1)

    private static let lifeNow = Date(timeIntervalSince1970: 1_000_000)
    private static let activeWin: TimeInterval = 300        // 5 min
    private static let retentionWin: TimeInterval = 86_400  // 24h

    private func lifeSession(
        source: String? = nil,
        agoSeconds: TimeInterval,
        disconnectedAgoSeconds: TimeInterval? = nil
    ) -> Session {
        var session = Session(sessionId: "s", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        session.source = source
        session.lastActivity = Self.lifeNow.addingTimeInterval(-agoSeconds)
        if let disconnectedAgoSeconds {
            session.disconnectedAt = Self.lifeNow.addingTimeInterval(-disconnectedAgoSeconds)
        }
        return session
    }

    private func life(
        _ session: Session,
        _ hostClass: SessionHostClass,
        alive: Bool,
        desktopAppRunning: Bool? = nil
    ) -> SessionLifecycle {
        SessionLifecyclePolicy.lifecycle(
            for: session,
            hostClass: hostClass,
            processAlive: alive,
            now: Self.lifeNow,
            windows: LifecycleWindows(active: Self.activeWin, retention: Self.retentionWin),
            desktopAppRunning: desktopAppRunning
        )
    }

    private func connection(
        _ session: Session,
        _ hostClass: SessionHostClass,
        alive: Bool,
        desktopAppRunning: Bool? = nil
    ) -> SessionConnectionState {
        SessionLifecyclePolicy.connectionState(
            for: session, hostClass: hostClass, processAlive: alive, now: Self.lifeNow,
            windows: LifecycleWindows(active: Self.activeWin, retention: Self.retentionWin),
            desktopAppRunning: desktopAppRunning
        )
    }

    func testBuildCandidatesKeepsDesktopSessionActiveWhenHostAppIsRunning() throws {
        let root = NSTemporaryDirectory() + "cctop-running-desktop-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let sessionPath = (root as NSString).appendingPathComponent("codex-stale.json")
        var session = lifeSession(source: Session.codexSource, agoSeconds: 10_000, disconnectedAgoSeconds: 10_000)
        session.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        session.pid = nil
        try session.writeToFile(path: sessionPath)

        let candidates = SessionManager.buildCandidates(
            [URL(fileURLWithPath: sessionPath)],
            now: Self.lifeNow,
            desktopAppConnectionLookup: DesktopAppConnectionLookup { bundleID in
                bundleID == HostAppBundleID.codexDesktop
            }
        )

        XCTAssertEqual(candidates.map(\.session.lifecycle), [.active])
    }

    @MainActor
    func testSessionManagerClearsDisconnectedAtWhenDesktopHostAppIsRunning() throws {
        let root = NSTemporaryDirectory() + "cctop-desktop-reconnected-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        setenv("CCTOP_SESSIONS_DIR", sessionsDir, 1)
        defer {
            unsetenv("CCTOP_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-reconnected.json")
        var session = lifeSession(source: Session.codexSource, agoSeconds: 10_000, disconnectedAgoSeconds: 10_000)
        session.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        session.pid = nil
        try session.writeToFile(path: sessionPath)

        var manager: SessionManager? = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            desktopAppConnectionLookup: DesktopAppConnectionLookup { bundleID in
                bundleID == HostAppBundleID.codexDesktop
            }
        )

        XCTAssertEqual(manager?.sessions.map(\.lifecycle), [.active])
        XCTAssertNil(try Session.fromFile(path: sessionPath).disconnectedAt)

        manager = nil
    }

    @MainActor
    func testSessionManagerKeepsEndedDesktopSessionDormantWhenHostAppIsRunning() throws {
        let root = NSTemporaryDirectory() + "cctop-ended-desktop-running-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        setenv("CCTOP_SESSIONS_DIR", sessionsDir, 1)
        defer {
            unsetenv("CCTOP_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-ended.json")
        var session = lifeSession(source: Session.codexSource, agoSeconds: 10_000, disconnectedAgoSeconds: 10_000)
        session.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        session.pid = nil
        let disconnectedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 60)
        session.endedAt = disconnectedAt.addingTimeInterval(30)
        session.disconnectedAt = disconnectedAt
        try session.writeToFile(path: sessionPath)

        var manager: SessionManager? = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            desktopAppConnectionLookup: DesktopAppConnectionLookup { bundleID in
                bundleID == HostAppBundleID.codexDesktop
            }
        )

        XCTAssertEqual(manager?.sessions.map(\.lifecycle), [.dormant])
        XCTAssertEqual(try Session.fromFile(path: sessionPath).disconnectedAt, disconnectedAt)

        manager = nil
    }

    func testIdentityPolicyNamesStableGroupingRules() {
        var codex = Session(sessionId: "codex-conversation", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        codex.source = Session.codexSource
        codex.lastActivity = Self.lifeNow.addingTimeInterval(-60)
        codex.pid = 31349

        var desktop = Session(sessionId: "desktop-conversation", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        desktop.source = "cc"
        desktop.lastActivity = Self.lifeNow.addingTimeInterval(-60)
        desktop.terminal = TerminalInfo(bundleId: HostAppBundleID.claudeDesktop)
        desktop.pid = 99

        var terminal = Session(sessionId: "terminal-conversation", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        terminal.source = "cc"
        terminal.lastActivity = Self.lifeNow.addingTimeInterval(-60)
        terminal.pid = 42

        XCTAssertEqual(SessionIdentityPolicy.stableKey(for: codex), "codex:codex-conversation")
        XCTAssertEqual(SessionIdentityPolicy.stableKey(for: desktop), "desktop:desktop-conversation")
        XCTAssertEqual(SessionIdentityPolicy.stableKey(for: terminal), "active:42")
    }

    func testConnectionStateUsesEndedAtForAllHosts() {
        var session = lifeSession(agoSeconds: 60)
        session.endedAt = Self.lifeNow.addingTimeInterval(-30)

        XCTAssertEqual(connection(session, .desktop, alive: true), .disconnected)
        XCTAssertEqual(connection(session, .terminal, alive: true), .disconnected)
        XCTAssertEqual(connection(session, .ambiguous, alive: true), .disconnected)
    }

    func testLifecycleMapsSameDisconnectedStateByHostPolicy() {
        let session = lifeSession(agoSeconds: 60, disconnectedAgoSeconds: 30)

        XCTAssertEqual(life(session, .desktop, alive: false), .dormant)
        XCTAssertEqual(life(session, .terminal, alive: false), .finished)
        XCTAssertEqual(life(session, .ambiguous, alive: false), .finished)
    }

    func testLifecycleDesktopAliveIsActive() {
        XCTAssertEqual(life(lifeSession(agoSeconds: 0), .desktop, alive: true), .active)
    }

    func testLifecycleDesktopDeadButRecentIsDormant() {
        XCTAssertEqual(life(lifeSession(agoSeconds: 60), .desktop, alive: false), .dormant)
    }

    func testLifecycleDesktopDeadAndAgedIsFinished() {
        XCTAssertEqual(
            life(lifeSession(agoSeconds: 100_000, disconnectedAgoSeconds: 100_000), .desktop, alive: false),
            .finished
        )
    }

    func testLifecycleDesktopDeadUsesDisconnectedAtInsteadOfLastActivityForRetention() {
        XCTAssertEqual(
            life(lifeSession(agoSeconds: 100_000, disconnectedAgoSeconds: 60), .desktop, alive: false),
            .dormant
        )
    }

    func testLifecycleDesktopDeadWithoutDisconnectedAtStartsDormant() {
        XCTAssertEqual(life(lifeSession(agoSeconds: 100_000), .desktop, alive: false), .dormant)
    }

    func testLifecycleClaudeDesktopUsesDesktopDormantPolicy() {
        var session = lifeSession(agoSeconds: 100_000, disconnectedAgoSeconds: 60)
        session.terminal = TerminalInfo(bundleId: HostAppBundleID.claudeDesktop)

        XCTAssertEqual(session.hostClass, .desktop)
        XCTAssertEqual(life(session, session.hostClass, alive: false), .dormant)
        XCTAssertEqual(life(session, session.hostClass, alive: true), .active)
    }

    func testLifecycleUnknownHostDeadIsFinishedEvenIfRecent() {
        XCTAssertEqual(life(lifeSession(agoSeconds: 60), .ambiguous, alive: false), .finished)
    }

    func testLifecycleTerminalAliveIsActive() {
        XCTAssertEqual(life(lifeSession(agoSeconds: 0), .terminal, alive: true), .active)
    }

    // A dead terminal session is over — no dormant, even when recent.
    func testLifecycleTerminalDeadIsFinishedEvenIfRecent() {
        XCTAssertEqual(life(lifeSession(agoSeconds: 60), .terminal, alive: false), .finished)
    }

    func testLifecycleTerminalEndedAtIsFinishedEvenIfPidStillAlive() {
        var session = lifeSession(agoSeconds: 60)
        session.endedAt = Self.lifeNow.addingTimeInterval(-30)
        XCTAssertEqual(life(session, .terminal, alive: true), .finished)
    }

    func testLifecycleDesktopEndedAtUsesDesktopDormantRules() {
        var session = lifeSession(agoSeconds: 60, disconnectedAgoSeconds: 30)
        session.endedAt = Self.lifeNow.addingTimeInterval(-30)
        XCTAssertEqual(life(session, .desktop, alive: false), .dormant)
    }

    func testLifecycleDesktopEndedAtBeatsPidLiveness() {
        var session = lifeSession(agoSeconds: 60, disconnectedAgoSeconds: 30)
        session.endedAt = Self.lifeNow.addingTimeInterval(-30)
        XCTAssertEqual(life(session, .desktop, alive: true), .dormant)
    }

    func testLifecycleDesktopEndedAtBeatsDesktopAppRunning() {
        var session = lifeSession(agoSeconds: 60, disconnectedAgoSeconds: 30)
        session.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        session.endedAt = Self.lifeNow.addingTimeInterval(-30)
        XCTAssertEqual(connection(session, .desktop, alive: false, desktopAppRunning: true), .disconnected)
        XCTAssertEqual(life(session, .desktop, alive: false, desktopAppRunning: true), .dormant)
    }

    func testLifecycleDesktopAppRunningKeepsStaleCodexSessionActive() {
        var session = lifeSession(source: "codex", agoSeconds: 600, disconnectedAgoSeconds: 60)
        session.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        XCTAssertEqual(life(session, .desktop, alive: false, desktopAppRunning: true), .active)
    }

    func testLifecycleDesktopAppStoppedMakesRecentCodexSessionDormant() {
        var session = lifeSession(source: "codex", agoSeconds: 30, disconnectedAgoSeconds: 60)
        session.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        XCTAssertEqual(life(session, .desktop, alive: false, desktopAppRunning: false), .dormant)
    }

    func testLifecycleDesktopAppSignalDoesNotAffectCodexCliTerminal() {
        XCTAssertEqual(
            life(lifeSession(source: "codex", agoSeconds: 30), .terminal, alive: false, desktopAppRunning: true),
            .finished
        )
    }

    // Codex Desktop fallback: without app-level liveness, a live SHARED host PID must not keep a
    // stale conversation active.
    func testLifecycleCodexDesktopWithoutAppLivenessFallsBackToRecencyWhenStale() {
        XCTAssertEqual(life(lifeSession(source: "codex", agoSeconds: 600), .desktop, alive: true), .dormant)
    }

    // Codex Desktop fallback: without app-level liveness, recent activity still keeps the record active.
    func testLifecycleCodexDesktopWithoutAppLivenessFallsBackToRecentActivity() {
        XCTAssertEqual(life(lifeSession(source: "codex", agoSeconds: 30), .desktop, alive: false), .active)
    }

    // Codex CLI (terminal) uses its REAL per-process PID, not recency — never remove a live silent CLI.
    func testLifecycleCodexCliTerminalUsesRealPidNotRecency() {
        XCTAssertEqual(life(lifeSession(source: "codex", agoSeconds: 600), .terminal, alive: true), .active)
    }

    // Ambiguous + Codex with a LIVE pid stays active: ambiguous is the safety bucket, and a Codex
    // CLI without a recognized bundle id still has a real per-process PID — the shared-PID recency
    // carve-out applies ONLY to Codex Desktop (hostClass == .desktop), not to ambiguous.
    func testLifecycleAmbiguousCodexWithLivePidStaysActive() {
        XCTAssertEqual(life(lifeSession(source: "codex", agoSeconds: 600), .ambiguous, alive: true), .active)
    }

    // Fallback blocker: a Codex Desktop session with source == nil (pre-harness-migration files)
    // must still get the recency carve-out via its trusted bundle id when app liveness is absent.
    func testLifecycleCodexDesktopWithoutSourceUsesRecencyFallback() {
        var stale = lifeSession(agoSeconds: 600)   // source nil, stale activity
        stale.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        // A live SHARED host PID must not keep a stale conversation active.
        XCTAssertEqual(life(stale, .desktop, alive: true), .dormant)

        var recent = lifeSession(agoSeconds: 30)   // source nil, recent activity
        recent.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        // Recent activity means active even with a dead/irrelevant PID.
        XCTAssertEqual(life(recent, .desktop, alive: false), .active)
    }
}
