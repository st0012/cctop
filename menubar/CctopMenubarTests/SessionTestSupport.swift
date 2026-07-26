import XCTest
@testable import CctopMenubar

extension XCTestCase {
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
        gitOrigins: [String: String] = [:],
        cwds: [String: String] = [:],
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
        let metadataRows = Set(gitOrigins.keys).union(cwds.keys).map { threadID in
            """
            INSERT INTO threads (id, rollout_path, archived, thread_source, git_origin_url, cwd, source, has_user_event, first_user_message)
            VALUES (\(sqlValue(threadID)), '', 0, 'user', \(sqlValue(gitOrigins[threadID])), \(sqlValue(cwds[threadID])), 'vscode', 1, '');
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
        \(metadataRows)
        \(execHelperRows)
        \(execFirstMessageRows)
        \(userExecRows)
        \(spawnEdgeRows)
        """
        try executeSQLite(sql, path: path)
    }

    func codexTerminalSession(sessionId: String, projectPath: String) -> Session {
        var session = Session(
            sessionId: sessionId,
            projectPath: projectPath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh", bundleId: "com.googlecode.iterm2")
        )
        session.source = Session.codexSource
        session.pid = UInt32(ProcessInfo.processInfo.processIdentifier)
        session.status = .waitingInput
        return session
    }

    func codexDesktopSession(sessionId: String, projectPath: String) -> Session {
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

    func claudeDesktopSession(sessionId: String, projectPath: String) -> Session {
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
        desktopAppConnection: DesktopAppConnectionLookup? = nil,
        processAlive: ((Session) -> Bool)? = nil,
        manualSessionVisibility: ManualSessionVisibilityStore? = nil,
        now: (() -> Date)? = nil
    ) -> SessionManager {
        var sources = SessionDataSources.live()
        sources.sessionsDir = URL(fileURLWithPath: sessionsDir)
        if let desktopAppConnection {
            sources.desktopAppConnection = desktopAppConnection
        }
        if let processAlive {
            sources.processAlive = processAlive
        }
        if let manualSessionVisibility {
            sources.manualSessionVisibility = manualSessionVisibility
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
        update: (inout Session) -> Void = { _ in }
    ) -> DedupCandidate {
        var s = Session(sessionId: sessionId, projectPath: "/tmp/p", branch: "main",
                        terminal: TerminalInfo(bundleId: bundleId))
        s.pid = pid
        s.source = source
        s.lastActivity = lastActivity
        s.endedAt = endedAt
        s.disconnectedAt = disconnectedAt
        update(&s)
        return DedupCandidate(session: s, lifecycleRank: lifecycleRank, mtime: mtime, path: path)
    }
}

/// In-memory stand-in for Codex's thread state database, so visibility and archive logic can be
/// exercised without SQLite fixtures on disk. Set a field to `nil` to simulate an unreadable store.
struct StubCodexThreadState: CodexThreadStateProviding {
    var existing: Set<String>? = nil
    var archived: Set<String>? = []
    var subagents: Set<String>? = []
    var execHelpers: Set<String>? = []
    var projectNamesByThreadID: [String: String]? = [:]

    func stateIndex(matching threadIDs: Set<String>) -> CodexThreadStateIndex? {
        var index = CodexThreadStateIndex()
        index.existingThreadIDs = (existing ?? threadIDs).intersection(threadIDs)
        index.archivedThreadIDs = (archived ?? []).intersection(threadIDs)
        index.internalHelperThreadIDs = (subagents ?? []).intersection(threadIDs)
        index.execHelperThreadIDs = (execHelpers ?? []).intersection(threadIDs)
        index.projectNamesByThreadID = (projectNamesByThreadID ?? [:]).filter { threadIDs.contains($0.key) }
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

    func projectNames(matching threadIDs: Set<String>) -> [String: String]? {
        projectNamesByThreadID.map { $0.filter { threadIDs.contains($0.key) } }
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
