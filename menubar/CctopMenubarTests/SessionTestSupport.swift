import XCTest
@testable import CctopMenubar

extension XCTestCase {
    func isolatedManualSessionVisibility(prefix: String) -> ManualSessionVisibilityStore {
        let suiteName = "\(prefix)-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated user defaults")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return ManualSessionVisibilityStore(defaults: defaults)
    }

    func isolatedSessionDataSources(
        prefix: String
    ) throws -> SessionDataSources {
        let sessionsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: sessionsDir)
        }

        return isolatedSessionDataSources(
            sessionsDir: sessionsDir,
            visibilityPrefix: prefix
        )
    }

    func isolatedSessionDataSources(
        sessionsDir: URL,
        visibilityPrefix: String
    ) -> SessionDataSources {
        isolatedSessionDataSources(
            sessionsDir: sessionsDir,
            manualSessionVisibility: isolatedManualSessionVisibility(prefix: visibilityPrefix)
        )
    }

    func isolatedSessionDataSources(
        sessionsDir: URL,
        manualSessionVisibility: ManualSessionVisibilityStore
    ) -> SessionDataSources {
        let testProcessID = UInt32(ProcessInfo.processInfo.processIdentifier)
        return SessionDataSources(
            sessionsDir: sessionsDir,
            codexThreads: StubCodexThreadState(),
            claudeDesktopSessions: StubClaudeDesktopState(
                snapshot: ClaudeDesktopSessionMetadataSnapshot()
            ),
            desktopAppConnection: DesktopAppConnectionLookup { _ in false },
            processAlive: { $0.pid == testProcessID },
            notificationsEnabled: { false },
            notificationClient: SessionNotificationClient(
                add: { _, completion in completion(nil) },
                removePending: { _ in },
                removeDelivered: { _ in }
            ),
            manualSessionVisibility: manualSessionVisibility,
            now: Date.init
        )
    }

    func withTemporaryHomeDirectory<T>(
        _ homeDirectory: URL,
        body: () throws -> T
    ) rethrows -> T {
        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", homeDirectory.path, 1)
        defer {
            if let previousHome {
                setenv("HOME", previousHome, 1)
            } else {
                unsetenv("HOME")
            }
        }
        return try body()
    }

    func executeSQLite(_ sql: String, path: String) throws {
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

    func sqlValue(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    func writeCodexStateDatabase(
        path: String,
        archivedThreads: Set<String>,
        subagentThreads: Set<String> = [],
        delegatedThreads: Set<String> = [],
        execHelperThreads: Set<String> = [],
        execThreadsWithFirstUserMessage: [String: String] = [:],
        userExecThreads: Set<String> = []
    ) throws {
        let rolloutDir = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("rollouts")
        try FileManager.default.createDirectory(atPath: rolloutDir, withIntermediateDirectories: true)
        func rolloutPath(threadID: String, originator: String) throws -> String {
            let filePath = (rolloutDir as NSString).appendingPathComponent("\(threadID).jsonl")
            let object: [String: Any] = [
                "type": "session_meta",
                "payload": [
                    "id": threadID,
                    "originator": originator,
                    "source": "exec"
                ]
            ]
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(0x0a)
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            return filePath
        }

        let archivedRows = archivedThreads.map {
            """
            INSERT INTO threads (id, rollout_path, archived, thread_source, git_origin_url, cwd, source, has_user_event, first_user_message)
            VALUES (\(sqlValue($0)), '', 1, 'user', NULL, NULL, 'vscode', 1, '');
            """
        }.joined(separator: "\n")
        let subagentRows = subagentThreads.map { threadID in
            let source = """
            {"subagent":{"thread_spawn":{"parent_thread_id":"fixture-parent","depth":1,"agent_path":null,"agent_nickname":null,"agent_role":null}}}
            """
            return """
            INSERT INTO threads (id, rollout_path, archived, thread_source, git_origin_url, cwd, source, has_user_event, first_user_message)
            VALUES (\(sqlValue(threadID)), '', 0, 'subagent', NULL, NULL, \(sqlValue(source)), 0, '');
            """
        }.joined(separator: "\n")
        let delegatedRows = delegatedThreads.map {
            """
            INSERT INTO threads (id, rollout_path, archived, thread_source, git_origin_url, cwd, source, has_user_event, first_user_message)
            VALUES (\(sqlValue($0)), '', 0, 'subagent', NULL, NULL, 'vscode', 1, '');
            """
        }.joined(separator: "\n")
        let spawnEdgeRows = subagentThreads.map {
            """
            INSERT INTO thread_spawn_edges (parent_thread_id, child_thread_id, status)
            VALUES ('fixture-parent', \(sqlValue($0)), 'open');
            """
        }.joined(separator: "\n")
        let execHelperRows = try execHelperThreads.map {
            let rollout = try rolloutPath(threadID: $0, originator: "Codex Desktop")
            return """
            INSERT INTO threads (id, rollout_path, archived, thread_source, git_origin_url, cwd, source, has_user_event, first_user_message)
            VALUES (\(sqlValue($0)), \(sqlValue(rollout)), 0, '', NULL, NULL, 'exec', 0, 'Review the release diff');
            """
        }.joined(separator: "\n")
        let execFirstMessageRows = try execThreadsWithFirstUserMessage.map { threadID, firstUserMessage in
            let rollout = try rolloutPath(threadID: threadID, originator: "codex_exec")
            return """
            INSERT INTO threads (id, rollout_path, archived, thread_source, git_origin_url, cwd, source, has_user_event, first_user_message)
            VALUES (\(sqlValue(threadID)), \(sqlValue(rollout)), 0, '', NULL, NULL, 'exec', 0, \(sqlValue(firstUserMessage)));
            """
        }.joined(separator: "\n")
        let userExecRows = userExecThreads.map {
            """
            INSERT INTO threads (id, rollout_path, archived, thread_source, git_origin_url, cwd, source, has_user_event, first_user_message)
            VALUES (\(sqlValue($0)), '', 0, '', NULL, NULL, 'exec', 1, '');
            """
        }.joined(separator: "\n")
        let sql = """
        DROP TABLE IF EXISTS threads;
        DROP TABLE IF EXISTS thread_spawn_edges;
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL DEFAULT '',
            archived INTEGER NOT NULL DEFAULT 0,
            thread_source TEXT,
            git_origin_url TEXT,
            cwd TEXT,
            source TEXT NOT NULL DEFAULT '',
            has_user_event INTEGER NOT NULL DEFAULT 0,
            first_user_message TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE thread_spawn_edges (
            parent_thread_id TEXT NOT NULL,
            child_thread_id TEXT NOT NULL PRIMARY KEY,
            status TEXT NOT NULL
        );
        \(archivedRows)
        \(subagentRows)
        \(delegatedRows)
        \(execHelperRows)
        \(execFirstMessageRows)
        \(userExecRows)
        \(spawnEdgeRows)
        """
        try executeSQLite(sql, path: path)
    }

    func codexTerminalSession(sessionId: String, projectPath: String) -> SessionData {
        var session = SessionData(
            sessionId: sessionId,
            projectPath: projectPath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh", bundleId: "com.googlecode.iterm2")
        )
        session.source = SessionData.codexSource
        session.pid = UInt32(ProcessInfo.processInfo.processIdentifier)
        session.status = .waitingInput
        return session
    }

    func codexSession(sessionId: String, projectPath: String) -> SessionData {
        var session = SessionData(
            sessionId: sessionId,
            projectPath: projectPath,
            branch: "main",
            terminal: TerminalInfo()
        )
        session.source = SessionData.codexSource
        session.pid = UInt32(ProcessInfo.processInfo.processIdentifier)
        session.status = .waitingInput
        return session
    }

    func claudeDesktopSession(sessionId: String, projectPath: String) -> SessionData {
        var session = SessionData(
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

    func writeClaudeDesktopSessionMetadata(
        root: String,
        cliSessionId: String,
        isArchived: Bool,
        lastActivityAt: Any? = nil,
        originCwd: Any? = nil,
        worktreeName: Any? = nil
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
        if let originCwd {
            payload["originCwd"] = originCwd
        }
        if let worktreeName {
            payload["worktreeName"] = worktreeName
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: URL(fileURLWithPath: metadataPath))
    }

    /// Constructs a SessionManager against a temp sessions directory with injected data sources
    /// and no background monitoring, replacing the old setenv(CCTOP_SESSIONS_DIR) ceremony.
    @MainActor
    func makeManager(
        sessionsDir: String,
        historyDir: String,
        codexThreads: (any CodexThreadStateProviding)? = nil,
        claudeDesktopSessions: (any ClaudeDesktopSessionStateProviding)? = nil,
        desktopAppConnection: DesktopAppConnectionLookup? = nil,
        processAlive: ((SessionData) -> Bool)? = nil,
        manualSessionVisibility: ManualSessionVisibilityStore? = nil,
        now: (() -> Date)? = nil
    ) -> SessionManager {
        let visibility = manualSessionVisibility
            ?? isolatedManualSessionVisibility(prefix: "cctop-manager")
        var sources = isolatedSessionDataSources(
            sessionsDir: URL(fileURLWithPath: sessionsDir),
            manualSessionVisibility: visibility
        )
        if let codexThreads {
            sources.codexThreads = codexThreads
        }
        if let claudeDesktopSessions {
            sources.claudeDesktopSessions = claudeDesktopSessions
        }
        if let desktopAppConnection {
            sources.desktopAppConnection = desktopAppConnection
        }
        if let processAlive {
            sources.processAlive = processAlive
        }
        if let now {
            sources.now = now
        }
        return SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )
    }

    func candidate(
        sessionId: String, pid: UInt32, bundleId: String?, lifecycleRank: Int,
        source: String? = nil,
        lastActivity: Date = Date(timeIntervalSince1970: 1000),
        endedAt: Date? = nil, disconnectedAt: Date? = nil, mtime: Date = .distantPast, path: String = "/x.json",
        update: (inout SessionData) -> Void = { _ in }
    ) -> SessionRecord {
        var s = SessionData(sessionId: sessionId, projectPath: "/tmp/p", branch: "main",
                        terminal: TerminalInfo(bundleId: bundleId))
        s.pid = pid
        s.source = source
        s.lastActivity = lastActivity
        s.endedAt = endedAt
        s.disconnectedAt = disconnectedAt
        update(&s)
        return SessionRecord(data: s, lifecycleRank: lifecycleRank, mtime: mtime, path: path)
    }

    /// Runs raw test fixtures forward through the same record and grouping stages as production.
    func userSessions(fromDataFixtures dataFixtures: [SessionData]) -> [UserSession] {
        let records = dataFixtures.enumerated().map { index, data in
            SessionRecord(
                data: data,
                lifecycleRank: data.lifecycle.rawValue,
                mtime: .distantPast,
                path: "/test-source-record-\(index).json"
            )
        }
        return UserSession.grouping(
            winners: SessionIdentityPolicy.dedupedCandidatesByStableKey(records),
            records: records
        )
    }

    func userSession(
        identity: SessionIdentityPolicy.LogicalIdentity,
        display: SessionData,
        records: [SessionData]
    ) -> UserSession {
        let sessionRecords = records.enumerated().map { index, data in
            SessionRecord(
                data: data,
                lifecycleRank: data.lifecycle.rawValue,
                mtime: .distantPast,
                path: "/test-user-session-\(index).json"
            )
        }
        let displayRecord = sessionRecords.first { $0.data == display }
            ?? SessionRecord(
                data: display,
                lifecycleRank: display.lifecycle.rawValue,
                mtime: .distantPast,
                path: "/test-user-session-display.json"
            )
        return UserSession(
            identity: identity,
            records: sessionRecords,
            displayRecord: displayRecord
        )
    }
}

/// In-memory stand-in for Codex's thread state database, so visibility and archive logic can be
/// exercised without SQLite fixtures on disk. Set a field to `nil` to simulate an unreadable store.
struct StubCodexThreadState: CodexThreadStateProviding {
    var existing: Set<String>? = nil
    var archived: Set<String>? = []
    var subagents: Set<String>? = []
    var execHelpers: Set<String>? = []

    func stateIndex(matching threadIDs: Set<String>) -> CodexThreadStateIndex? {
        var index = CodexThreadStateIndex()
        index.existingThreadIDs = (existing ?? threadIDs).intersection(threadIDs)
        index.archivedThreadIDs = (archived ?? []).intersection(threadIDs)
        index.internalHelperThreadIDs = (subagents ?? []).intersection(threadIDs)
        index.execHelperThreadIDs = (execHelpers ?? []).intersection(threadIDs)
        return index
    }

    func existingThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        existing.map { $0.intersection(threadIDs) }
    }

    func archivedThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        archived.map { $0.intersection(threadIDs) }
    }

    func internalHelperThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        subagents.map { $0.intersection(threadIDs) }
    }

    func execHelperThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        execHelpers.map { $0.intersection(threadIDs) }
    }

}

/// In-memory stand-in for Claude Desktop's session metadata store. `nil` simulates an
/// unreadable store.
struct StubClaudeDesktopState: ClaudeDesktopSessionStateProviding {
    var snapshot: ClaudeDesktopSessionMetadataSnapshot?

    func archivedSessionIDs(matching sessionIDs: Set<String>) -> Set<String>? {
        snapshot?.archivedSessionIDs
    }

    func metadataSnapshot(matching sessionIDs: Set<String>) -> ClaudeDesktopSessionMetadataSnapshot? {
        snapshot
    }
}

// MARK: - QA snapshot fixtures

extension SessionData {
    /// 8 sessions: tests scrolling behavior.
    static let qaEightSessions: [SessionData] = qaSixSessions + [
        .mock(id: "7", project: "mobile-app", branch: "release/2.0",
              status: .waitingPermission, notificationMessage: "Allow Write: /config/prod.json"),
        .mock(id: "8", project: "analytics", branch: "fix/dashboard", status: .working, lastTool: "Grep", lastToolDetail: "*.ts"),
    ]

    /// All sessions needing attention (only amber badge visible).
    static let qaAllAttention: [SessionData] = [
        .mock(id: "1", project: "web-app", branch: "main", status: .waitingPermission, notificationMessage: "Allow Bash: rm -rf node_modules"),
        .mock(id: "2", project: "api", branch: "develop", status: .waitingInput, lastPrompt: "Which database migration strategy?"),
        .mock(id: "3", project: "worker", branch: "main", status: .needsAttention),
    ]

    /// All sessions idle (only gray badge visible).
    static let qaAllIdle: [SessionData] = [
        .mock(id: "1", project: "project-a", branch: "main", status: .idle),
        .mock(id: "2", project: "project-b", branch: "develop", status: .idle),
        .mock(id: "3", project: "project-c", branch: "main", status: .idle),
        .mock(id: "4", project: "project-d", branch: "feature/x", status: .idle),
    ]

    /// Long project and branch names to test truncation.
    static let qaLongNames: [SessionData] = [
        .mock(id: "1", project: "my-very-long-project-name-here",
              branch: "feature/JIRA-12345-implement-oauth2-refresh-token-rotation",
              status: .working, lastTool: "Edit",
              lastToolDetail: "/src/authentication/middleware/refresh-token-handler.ts"),
        .mock(id: "2", project: "another-extremely-long-name",
              branch: "fix/bug-that-has-a-really-long-description",
              status: .waitingInput,
              lastPrompt: "This is a very long prompt that should be truncated"),
        .mock(id: "3", project: "short", branch: "m", status: .idle),
    ]

    /// Long session names to test wrapping (e.g. forked sessions using first message as name).
    static let qaLongSessionNames: [SessionData] = [
        .mock(id: "1", project: "cctop",
              branch: "redesign",
              sessionName: "Can you use test data to show me what happens if the session name is super long like over 50 characters",
              status: .working, lastTool: "Edit",
              lastToolDetail: "/Users/test/projects/cctop/Views/SessionCardView.swift"),
        .mock(id: "2", project: "cctop",
              branch: "main",
              sessionName: "Help me refactor the authentication middleware to support OAuth2 refresh token rotation",
              status: .idle),
        .mock(id: "3", project: "blog",
              branch: "main",
              status: .idle),
    ]

    /// Single session.
    static let qaSingle: [SessionData] = [
        .mock(id: "1", project: "solo-project", branch: "main", status: .working, lastTool: "Task", lastToolDetail: "Running tests"),
    ]
}
