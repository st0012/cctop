import Darwin
import XCTest
@testable import CctopMenubar

final class SessionManagerVisibilityTests: XCTestCase {
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

        setenv("CCTOP_CODEX_MEMORIES_DIR", memoriesDir, 1)
        defer {
            unsetenv("CCTOP_CODEX_MEMORIES_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let memorySession = codexDesktopSession(sessionId: "memory-session", projectPath: memoriesDir)
        let memoryPath = (sessionsDir as NSString).appendingPathComponent("codex-memory-session.json")
        try memorySession.writeToFile(path: memoryPath)
        FileManager.default.createFile(atPath: memoryPath + ".lock", contents: nil)

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: memoryPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: memoryPath + ".lock"))
        XCTAssertTrue(try Session.fromFile(path: memoryPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    @MainActor
    func testSessionManagerHidesCodexDesktopTitleGenerationSessionsWithoutRemovingFiles() throws {
        let root = NSTemporaryDirectory() + "cctop-title-helper-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(atPath: root) }

        var titleGeneration = codexDesktopSession(
            sessionId: "title-helper",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        )
        titleGeneration.lastPrompt = codexTitleGenerationPrompt(for: "Why do I have several memories sessions?")
        let titleHelperPath = (sessionsDir as NSString).appendingPathComponent("codex-title-helper.json")
        try titleGeneration.writeToFile(path: titleHelperPath)
        FileManager.default.createFile(atPath: titleHelperPath + ".lock", contents: nil)

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: titleHelperPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: titleHelperPath + ".lock"))
        XCTAssertTrue(try Session.fromFile(path: titleHelperPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
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

        defer { try? FileManager.default.removeItem(atPath: root) }

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

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenPath))
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    @MainActor
    func testCleanupActivePathsIncludeHiddenLiveSessions() throws {
        let root = NSTemporaryDirectory() + "cctop-hidden-active-cleanup-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let worktreePath = (root as NSString).appendingPathComponent(".codex/worktrees/hidden-live")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(atPath: root) }

        var hidden = Session(
            sessionId: "hidden-live",
            projectPath: worktreePath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        hidden.hidden = true
        hidden.pid = 999_998
        let hiddenPath = (sessionsDir as NSString).appendingPathComponent("999998.json")
        try hidden.writeToFile(path: hiddenPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            processAlive: { $0.sessionId == "hidden-live" }
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [worktreePath])
    }

    @MainActor
    func testCleanupActivePathsIncludeAutoHiddenLiveSessions() throws {
        let root = NSTemporaryDirectory() + "cctop-auto-hidden-active-cleanup-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let worktreePath = (root as NSString).appendingPathComponent(".codex/worktrees/title-helper")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(atPath: root) }

        var titleGeneration = codexDesktopSession(sessionId: "title-helper-active", projectPath: worktreePath)
        titleGeneration.sessionName = nil
        titleGeneration.lastPrompt = codexTitleGenerationPrompt()
        titleGeneration.lastActivity = Date()
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-title-helper-active.json")
        try titleGeneration.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            desktopAppConnection: DesktopAppConnectionLookup { _ in true },
            processAlive: { $0.sessionId == "title-helper-active" }
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [worktreePath])
        XCTAssertTrue(try Session.fromFile(path: sessionPath).hidden)
    }

    @MainActor
    func testCleanupSnapshotForRemovalRefreshesHiddenActiveProtection() throws {
        let root = NSTemporaryDirectory() + "cctop-hidden-active-refresh-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let worktreePath = (root as NSString).appendingPathComponent(".codex/worktrees/late-hidden")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(atPath: root) }

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            processAlive: { $0.sessionId == "late-hidden" }
        )
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [])

        var hidden = Session(
            sessionId: "late-hidden",
            projectPath: worktreePath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        hidden.hidden = true
        hidden.pid = 999_997
        try hidden.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("999997.json"))

        let snapshot = manager.cleanupSnapshotForRemoval()

        XCTAssertEqual(snapshot.activeProjectPaths, [worktreePath])
    }

    @MainActor
    func testGarbageCollectRefreshPreservesHiddenCleanupProtection() throws {
        let root = NSTemporaryDirectory() + "cctop-gc-hidden-cleanup-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let protectedPath = (root as NSString).appendingPathComponent(".codex/worktrees/hidden-live")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(atPath: root) }

        var hidden = Session(
            sessionId: "hidden-live",
            projectPath: protectedPath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        hidden.hidden = true
        hidden.pid = 999_996
        try hidden.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("999996.json"))

        let old = Date(timeIntervalSinceNow: -SessionManager.lifecycleWindows.retention - 86_400)
        let finishedDesktopPath = (sessionsDir as NSString).appendingPathComponent("codex-finished-desktop.json")
        var finishedDesktop = codexDesktopSession(sessionId: "finished-desktop", projectPath: "/tmp/finished-desktop")
        finishedDesktop.lastActivity = old
        finishedDesktop.disconnectedAt = old
        try finishedDesktop.writeToFile(path: finishedDesktopPath)

        var sources = SessionDataSources.live()
        sources.sessionsDir = URL(fileURLWithPath: sessionsDir)
        sources.codexThreads = StubCodexThreadState(existing: ["finished-desktop"], archived: [])
        sources.claudeDesktopSessions = StubClaudeDesktopState(snapshot: ClaudeDesktopSessionMetadataSnapshot())
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in false }
        sources.processAlive = { $0.sessionId == "hidden-live" }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [protectedPath])

        var history = Session(
            sessionId: "history",
            projectPath: "/tmp/history",
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        history.endedAt = Date()
        try history.writeToFile(path: (historyDir as NSString).appendingPathComponent("history.json"))

        var refreshedActivePaths: Set<String>?
        manager.cleanupRefreshHandler = { _, activePaths in
            refreshedActivePaths = activePaths
        }

        manager.garbageCollectFinished()

        XCTAssertFalse(FileManager.default.fileExists(atPath: finishedDesktopPath))
        XCTAssertEqual(refreshedActivePaths, [protectedPath])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [protectedPath])
    }

    @MainActor
    func testGarbageCollectSkipsBusySessionLockWithoutBlockingMainActor() throws {
        let root = NSTemporaryDirectory() + "cctop-gc-busy-lock-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let old = Date(timeIntervalSinceNow: -SessionManager.lifecycleWindows.retention - 86_400)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-busy-finished-thread.json")
        var session = codexDesktopSession(sessionId: "busy-finished-thread", projectPath: "/tmp/p")
        session.lastActivity = old
        session.disconnectedAt = old
        try session.writeToFile(path: sessionPath)

        let readyPath = (root as NSString).appendingPathComponent("lock-ready")
        let lockHolder = try startSessionLockHolder(lockPath: sessionPath + ".lock", readyPath: readyPath, holdSeconds: 1.5)
        defer { terminateProcess(lockHolder) }

        var sources = SessionDataSources.live()
        sources.sessionsDir = URL(fileURLWithPath: sessionsDir)
        sources.codexThreads = StubCodexThreadState(existing: ["busy-finished-thread"], archived: [])
        sources.claudeDesktopSessions = StubClaudeDesktopState(snapshot: ClaudeDesktopSessionMetadataSnapshot())
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in false }
        sources.processAlive = { _ in false }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )

        let start = Date()
        manager.garbageCollectFinished()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.75)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
    }

    @MainActor
    func testSessionManagerHidesGenericSubagentSessionFilesWithoutArchivingOrRemovingThem() throws {
        let root = NSTemporaryDirectory() + "cctop-generic-subagent-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(atPath: root) }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("12345.json")
        let now = ISO8601DateFormatter().string(from: Date())
        let json = """
        {
          "session_id": "delegated-review",
          "project_path": "\(root)/projects/cctop",
          "project_name": "cctop",
          "branch": "main",
          "status": "working",
          "last_activity": "\(now)",
          "started_at": "\(now)",
          "terminal": {"program": "zsh"},
          "pid": \(ProcessInfo.processInfo.processIdentifier),
          "source": "opencode",
          "is_subagent": true
        }
        """
        try json.write(toFile: sessionPath, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: sessionPath + ".lock", contents: nil)

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath + ".lock"))
        XCTAssertTrue(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    @MainActor
    func testSessionManagerHidesCodexSubagentThreadsForAnyCodexHostWithoutRemovingFiles() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-subagents-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(
            path: stateDB,
            archivedThreads: [],
            subagentThreads: ["codex-cli-subagent", "codex-desktop-subagent"]
        )

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let cliPath = (sessionsDir as NSString).appendingPathComponent("codex-codex-cli-subagent.json")
        let desktopPath = (sessionsDir as NSString).appendingPathComponent("codex-codex-desktop-subagent.json")
        try codexTerminalSession(
            sessionId: "codex-cli-subagent",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        ).writeToFile(path: cliPath)
        try codexDesktopSession(
            sessionId: "codex-desktop-subagent",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        ).writeToFile(path: desktopPath)
        FileManager.default.createFile(atPath: cliPath + ".lock", contents: nil)
        FileManager.default.createFile(atPath: desktopPath + ".lock", contents: nil)

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cliPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: desktopPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cliPath + ".lock"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: desktopPath + ".lock"))
        XCTAssertTrue(try Session.fromFile(path: cliPath).hidden)
        XCTAssertTrue(try Session.fromFile(path: desktopPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    @MainActor
    func testSessionManagerFiltersCodexExecHelperThreadsWithoutRemovingFiles() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-exec-helper-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(
            path: stateDB,
            archivedThreads: [],
            execHelperThreads: ["codex-exec-helper"]
        )

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-codex-exec-helper.json")
        try codexDesktopSession(
            sessionId: "codex-exec-helper",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        ).writeToFile(path: sessionPath)
        FileManager.default.createFile(atPath: sessionPath + ".lock", contents: nil)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            desktopAppConnection: DesktopAppConnectionLookup { _ in true }
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath + ".lock"))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    @MainActor
    func testSessionManagerFiltersCodexDesktopSessionsMissingFromReadableStateWithoutRemovingFiles() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-missing-state-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: [], userExecThreads: ["visible-thread"])

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let missingPath = (sessionsDir as NSString).appendingPathComponent("codex-missing-thread.json")
        let visiblePath = (sessionsDir as NSString).appendingPathComponent("codex-visible-thread.json")
        var missing = codexDesktopSession(
            sessionId: "missing-thread",
            projectPath: (root as NSString).appendingPathComponent("projects/probe")
        )
        missing.lastActivity = now.addingTimeInterval(-SessionManager.codexMissingThreadGraceSeconds - 1)
        try missing.writeToFile(path: missingPath)
        var visible = codexDesktopSession(
            sessionId: "visible-thread",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        )
        visible.lastActivity = now
        try visible.writeToFile(path: visiblePath)
        FileManager.default.createFile(atPath: missingPath + ".lock", contents: nil)
        FileManager.default.createFile(atPath: visiblePath + ".lock", contents: nil)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            desktopAppConnection: DesktopAppConnectionLookup { _ in true },
            now: { now }
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["visible-thread"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: missingPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: missingPath + ".lock"))
        XCTAssertFalse(try Session.fromFile(path: missingPath).hidden)
        XCTAssertTrue(FileManager.default.fileExists(atPath: visiblePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: visiblePath + ".lock"))
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    @MainActor
    func testSessionManagerKeepsFreshCodexDesktopSessionVisibleWhileThreadStateCatchesUp() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-fresh-missing-state-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: [], userExecThreads: ["other-thread"])

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-fresh-thread.json")
        var session = codexDesktopSession(
            sessionId: "fresh-thread",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        )
        session.lastActivity = now.addingTimeInterval(-SessionManager.codexMissingThreadGraceSeconds / 2)
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            desktopAppConnection: DesktopAppConnectionLookup { _ in true },
            now: { now }
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["fresh-thread"])
        XCTAssertEqual(
            SessionDisplayPolicy.activeSessions(from: manager.sessions, now: now).map(\.sessionId),
            ["fresh-thread"]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    @MainActor
    func testSessionManagerKeepsUserVisibleCodexExecThreads() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-user-exec-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(
            path: stateDB,
            archivedThreads: [],
            userExecThreads: ["codex-user-exec"]
        )

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-codex-user-exec.json")
        try codexDesktopSession(
            sessionId: "codex-user-exec",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        ).writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            desktopAppConnection: DesktopAppConnectionLookup { _ in true }
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["codex-user-exec"])
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
    }

    @MainActor
    func testSessionManagerKeepsCodexExecThreadsWithFirstUserMessageVisible() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-exec-first-message-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(
            path: stateDB,
            archivedThreads: [],
            execThreadsWithFirstUserMessage: ["codex-exec-first-message": "Review this diff"]
        )

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-codex-exec-first-message.json")
        try codexDesktopSession(
            sessionId: "codex-exec-first-message",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        ).writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            desktopAppConnection: DesktopAppConnectionLookup { _ in true }
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["codex-exec-first-message"])
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
    }

    @MainActor
    func testSessionManagerKeepsParentSessionWithActiveSubagentsVisible() throws {
        let root = NSTemporaryDirectory() + "cctop-parent-subagents-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: [], userExecThreads: ["parent-thread"])

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-parent-thread.json")
        var session = codexDesktopSession(
            sessionId: "parent-thread",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        )
        session.activeSubagents = [
            SubagentInfo(agentId: "agent-1", agentType: "reviewer", startedAt: Date(timeIntervalSince1970: 100))
        ]
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            desktopAppConnection: DesktopAppConnectionLookup { _ in true }
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["parent-thread"])
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
    }

    @MainActor
    func testSessionManagerRemovesFinishedCodexDedupLoserWithoutArchiving() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-dedup-cleanup-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: [], userExecThreads: ["conv-a"])

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
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

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        manager.loadSessions()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: desktopPath))
        XCTAssertEqual(manager.sessions.map(\.sessionId), ["conv-a"])
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
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

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-archived-thread.json")
        var session = codexDesktopSession(sessionId: "archived-thread", projectPath: "/tmp/p")
        session.lastActivity = Date()
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), [])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), ["archived-thread"])
        XCTAssertEqual(manager.cleanupSources.map(\.projectPath), ["/tmp/p"])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)

        try writeCodexStateDatabase(path: stateDB, archivedThreads: [], userExecThreads: ["archived-thread"])
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["archived-thread"])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), [])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, ["/tmp/p"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
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

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-archived-without-source.json")
        var session = codexDesktopSession(sessionId: "archived-without-source", projectPath: "/tmp/p")
        session.source = nil
        session.lastActivity = Date()
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), [])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), ["archived-without-source"])
        XCTAssertEqual(manager.cleanupSources.map(\.projectPath), ["/tmp/p"])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)

        try writeCodexStateDatabase(path: stateDB, archivedThreads: [])
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["archived-without-source"])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), [])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, ["/tmp/p"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
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

        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", claudeDir, 1)
        defer {
            unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("archived-claude-session.json")
        var session = claudeDesktopSession(sessionId: "archived-claude-session", projectPath: "/tmp/p")
        session.lastActivity = Date()
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), [])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), ["archived-claude-session"])
        XCTAssertEqual(manager.cleanupSources.map(\.projectPath), ["/tmp/p"])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)

        try FileManager.default.removeItem(atPath: claudeDir)
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "archived-claude-session",
            isArchived: false
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["archived-claude-session"])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), [])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, ["/tmp/p"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
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

        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", claudeDir, 1)
        defer {
            unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("archived-claude-without-source.json")
        var session = claudeDesktopSession(sessionId: "archived-claude-without-source", projectPath: "/tmp/p")
        session.source = nil
        session.lastActivity = Date()
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), [])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), ["archived-claude-without-source"])
        XCTAssertEqual(manager.cleanupSources.map(\.projectPath), ["/tmp/p"])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
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

        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", claudeDir, 1)
        defer {
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

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
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

    func testIsCodexDesktopThreadArchivedIgnoresOpencodeWithLeakedCodexDesktopBundle() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-archived-opencode-\(UUID().uuidString)"
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: ["opencode-39189"])
        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        var session = Session(
            sessionId: "opencode-39189", projectPath: "/tmp/p", branch: "main",
            terminal: TerminalInfo(bundleId: "com.openai.codex")
        )
        session.source = "opencode"

        XCTAssertFalse(SessionManager.isCodexDesktopThreadArchived(session))
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

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
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

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            desktopAppConnection: DesktopAppConnectionLookup { _ in false }
        )

        try writeCodexStateDatabase(path: stateDB, archivedThreads: ["finished-thread"])
        manager.garbageCollectFinished()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))

        try writeCodexStateDatabase(path: stateDB, archivedThreads: [])
        manager.garbageCollectFinished()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPath))
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

        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", claudeDir, 1)
        defer {
            unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let old = Date(timeIntervalSinceNow: -SessionManager.lifecycleWindows.retention - 86_400)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("finished-claude-session.json")
        var session = claudeDesktopSession(sessionId: "finished-claude-session", projectPath: "/tmp/p")
        session.lastActivity = old
        session.disconnectedAt = old
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            desktopAppConnection: DesktopAppConnectionLookup { _ in false }
        )

        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "finished-claude-session",
            isArchived: true
        )
        manager.garbageCollectFinished()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))

        try FileManager.default.removeItem(atPath: claudeDir)
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "finished-claude-session",
            isArchived: false
        )
        manager.garbageCollectFinished()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPath))
    }

    @MainActor
    func testGarbageCollectBatchesClaudeArchiveLookupForFinishedDesktopSessions() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-batched-gc-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let old = Date(timeIntervalSinceNow: -SessionManager.lifecycleWindows.retention - 86_400)
        for sessionId in ["finished-claude-one", "finished-claude-two"] {
            let sessionPath = (sessionsDir as NSString).appendingPathComponent("\(sessionId).json")
            var session = claudeDesktopSession(sessionId: sessionId, projectPath: "/tmp/p")
            session.lastActivity = old
            session.disconnectedAt = old
            try session.writeToFile(path: sessionPath)
        }

        let claudeState = CountingClaudeDesktopState()
        var sources = SessionDataSources.live()
        sources.sessionsDir = URL(fileURLWithPath: sessionsDir)
        sources.codexThreads = StubCodexThreadState()
        sources.claudeDesktopSessions = claudeState
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in false }
        sources.processAlive = { _ in false }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )

        claudeState.archivedRequests.removeAll()
        manager.garbageCollectFinished()

        XCTAssertEqual(claudeState.archivedRequests.count, 3)
        XCTAssertEqual(
            claudeState.archivedRequests.first,
            Set(["finished-claude-one", "finished-claude-two"])
        )
        XCTAssertEqual(
            Set(claudeState.archivedRequests.dropFirst()),
            Set([
                Set(["finished-claude-one"]),
                Set(["finished-claude-two"])
            ])
        )
    }

    @MainActor
    func testGarbageCollectRechecksClaudeArchiveStateUnderLockBeforeDeleting() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-gc-archive-race-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let old = Date(timeIntervalSinceNow: -SessionManager.lifecycleWindows.retention - 86_400)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("finished-claude-race.json")
        var session = claudeDesktopSession(sessionId: "finished-claude-race", projectPath: "/tmp/p")
        session.lastActivity = old
        session.disconnectedAt = old
        try session.writeToFile(path: sessionPath)

        let claudeState = SequencedClaudeDesktopState(archivedResponses: [[], ["finished-claude-race"]])
        var sources = SessionDataSources.live()
        sources.sessionsDir = URL(fileURLWithPath: sessionsDir)
        sources.codexThreads = StubCodexThreadState()
        sources.claudeDesktopSessions = claudeState
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in false }
        sources.processAlive = { _ in false }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )

        claudeState.archivedRequests.removeAll()
        manager.garbageCollectFinished()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
    }

    func testBuildCandidatesEnrichesDesktopProjectNameFromExternalMetadata() throws {
        let root = NSTemporaryDirectory() + "cctop-desktop-project-enrich-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", claudeDir, 1)
        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR")
            unsetenv("CCTOP_CODEX_STATE_DB")
        }

        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "claude-desktop-project",
            isArchived: false,
            originCwd: "/Users/dev/projects/cctop",
            worktreeName: "generated-worktree"
        )
        try writeCodexStateDatabase(
            path: stateDB,
            archivedThreads: [],
            cwds: ["codex-desktop-project": "/Users/dev/projects/rdoc"]
        )

        let claudePath = (sessionsDir as NSString).appendingPathComponent("claude.json")
        try claudeDesktopSession(
            sessionId: "claude-desktop-project",
            projectPath: "/tmp/generated-worktree"
        ).writeToFile(path: claudePath)

        let codexPath = (sessionsDir as NSString).appendingPathComponent("codex.json")
        try codexDesktopSession(
            sessionId: "codex-desktop-project",
            projectPath: "/tmp/other-generated-worktree"
        ).writeToFile(path: codexPath)

        let candidates = SessionManager.buildCandidates(
            [URL(fileURLWithPath: claudePath), URL(fileURLWithPath: codexPath)],
            now: Date(),
            desktopAppConnectionLookup: DesktopAppConnectionLookup { _ in true }
        )
        let namesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.session.sessionId, $0.session.desktopProjectName) })

        XCTAssertEqual(namesByID["claude-desktop-project"]!, "cctop")
        XCTAssertEqual(namesByID["codex-desktop-project"]!, "rdoc")
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

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
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
        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            desktopAppConnection: DesktopAppConnectionLookup { _ in false }
        )
        manager.garbageCollectFinished()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))

        // Once the DB is readable and shows the thread is not archived, GC reaps it. (Remove the
        // corrupt bytes first — sqlite3 cannot DROP/CREATE over a non-database file.)
        try FileManager.default.removeItem(atPath: stateDB)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: [])
        manager.garbageCollectFinished()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPath))
    }
}

private func startSessionLockHolder(lockPath: String, readyPath: String, holdSeconds: TimeInterval) throws -> Process {
    let script = """
    import fcntl
    import pathlib
    import sys
    import time

    lock_path, ready_path, hold_seconds = sys.argv[1], sys.argv[2], float(sys.argv[3])
    with open(lock_path, "a") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        pathlib.Path(ready_path).write_text("ready")
        time.sleep(hold_seconds)
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", script, lockPath, readyPath, String(holdSeconds)]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    try waitForFile(path: readyPath, process: process)
    return process
}

private func waitForFile(path: String, process: Process, timeout: TimeInterval = 10) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: path) { return }
        if !process.isRunning {
            throw NSError(
                domain: "CctopMenubarTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "lock holder exited before acquiring the lock"]
            )
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    throw NSError(
        domain: "CctopMenubarTests",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "timed out waiting for lock holder"]
    )
}

private func terminateProcess(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    process.waitUntilExit()
}

private final class CountingClaudeDesktopState: ClaudeDesktopSessionStateProviding {
    var archivedRequests: [Set<String>] = []

    func archivedSessionIDs(matching sessionIDs: Set<String>) -> Set<String>? {
        archivedRequests.append(sessionIDs)
        return []
    }

    func metadataSnapshot(matching sessionIDs: Set<String>) -> ClaudeDesktopSessionMetadataSnapshot? {
        ClaudeDesktopSessionMetadataSnapshot(
            matchedSessionIDs: sessionIDs,
            archivedSessionIDs: [],
            projectNamesBySessionID: [:],
            isAuthoritative: true
        )
    }
}

private final class SequencedClaudeDesktopState: ClaudeDesktopSessionStateProviding {
    var archivedRequests: [Set<String>] = []
    private var archivedResponses: [Set<String>]

    init(archivedResponses: [Set<String>]) {
        self.archivedResponses = archivedResponses
    }

    func archivedSessionIDs(matching sessionIDs: Set<String>) -> Set<String>? {
        archivedRequests.append(sessionIDs)
        let response = archivedResponses.isEmpty ? Set<String>() : archivedResponses.removeFirst()
        return response.intersection(sessionIDs)
    }

    func metadataSnapshot(matching sessionIDs: Set<String>) -> ClaudeDesktopSessionMetadataSnapshot? {
        ClaudeDesktopSessionMetadataSnapshot(
            matchedSessionIDs: sessionIDs,
            archivedSessionIDs: [],
            projectNamesBySessionID: [:],
            isAuthoritative: true
        )
    }
}
