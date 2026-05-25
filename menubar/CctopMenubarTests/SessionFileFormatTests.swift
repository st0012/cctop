import XCTest
@testable import CctopMenubar

final class SessionFileFormatTests: XCTestCase {
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

        let result = SessionManager.dedupedByID([old, fresh, other])
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
}
