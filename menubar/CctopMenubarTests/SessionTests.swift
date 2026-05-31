import XCTest
@testable import CctopMenubar

final class SessionTests: XCTestCase {
    func testDecodesRealSessionJSON() throws {
        let json = """
        {
            "session_id": "abc-123",
            "project_path": "/Users/test/projects/myapp",
            "project_name": "myapp",
            "branch": "main",
            "status": "working",
            "last_prompt": "Fix the bug",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code", "session_id": null, "tty": null},
            "pid": 12345,
            "last_tool": "Bash",
            "last_tool_detail": "npm test",
            "notification_message": null
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))

        XCTAssertEqual(session.sessionId, "abc-123")
        XCTAssertEqual(session.projectName, "myapp")
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(session.lastTool, "Bash")
        XCTAssertEqual(session.pid, 12345)
        XCTAssertFalse(session.hidden)
    }

    func testDecodesHiddenSessionJSON() throws {
        let json = """
        {
            "session_id": "hidden-1",
            "project_path": "/Users/test/projects/myapp",
            "project_name": "myapp",
            "branch": "main",
            "status": "working",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"},
            "hidden": true
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertTrue(session.hidden)
    }

    func testDecodesDateWithFractionalSeconds() throws {
        let json = """
        {
            "session_id": "frac-test",
            "project_path": "/tmp",
            "project_name": "test",
            "branch": "main",
            "status": "idle",
            "last_activity": "2026-02-08T12:00:00.123456Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"}
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.sessionId, "frac-test")
    }

    func testContextLineIdle() {
        let session = Session.mock(status: .idle)
        XCTAssertNil(session.contextLine)
    }

    func testContextLineWorking() {
        let session = Session.mock(status: .working, lastTool: "Bash", lastToolDetail: "npm test")
        XCTAssertEqual(session.contextLine, "Running: npm test")
    }

    func testContextLinePermission() {
        let session = Session.mock(status: .waitingPermission, notificationMessage: "Allow Bash: rm -rf /")
        XCTAssertEqual(session.contextLine, "Allow Bash: rm -rf /")
    }

    func testContextLinePermissionDefault() {
        let session = Session.mock(status: .waitingPermission)
        XCTAssertEqual(session.contextLine, "Permission needed")
    }

    func testContextLineWaitingInputPrefersNotificationMessage() {
        let session = Session.mock(
            status: .waitingInput,
            lastPrompt: "Original user prompt",
            notificationMessage: "Which direction should I take?"
        )
        XCTAssertEqual(session.contextLine, "Which direction should I take?")
    }

    func testContextLineWaitingInputFallsBackToPromptSnippet() {
        let session = Session.mock(
            status: .waitingInput,
            lastPrompt: "Original user prompt"
        )
        XCTAssertEqual(session.contextLine, "\"Original user prompt\"")
    }

    func testContextLineCompacting() {
        let session = Session.mock(status: .compacting)
        XCTAssertEqual(session.contextLine, "Compacting context...")
    }

    func testDecodesSessionName() throws {
        let json = """
        {
            "session_id": "named-1",
            "project_path": "/Users/test/projects/myapp",
            "project_name": "myapp",
            "branch": "main",
            "status": "working",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"},
            "session_name": "refactor auth"
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.sessionName, "refactor auth")
        XCTAssertEqual(session.displayName, "refactor auth")
    }

    func testDecodesWithoutSessionName() throws {
        let json = """
        {
            "session_id": "no-name-1",
            "project_path": "/Users/test/projects/myapp",
            "project_name": "myapp",
            "branch": "main",
            "status": "idle",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"}
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertNil(session.sessionName)
        XCTAssertEqual(session.displayName, "myapp")
    }

    func testDisplayNameReturnsSessionNameWhenSet() {
        let session = Session.mock(sessionName: "my task")
        XCTAssertEqual(session.displayName, "my task")
    }

    func testDisplayNameFallsBackToProjectName() {
        let session = Session.mock(project: "myapp")
        XCTAssertEqual(session.displayName, "myapp")
    }

    // MARK: - PID-keyed identity

    func testIdUsesPIDWhenAvailable() {
        let session = Session.mock(pid: 12345)
        XCTAssertEqual(session.id, "12345")
    }

    func testIdFallsBackToSessionIdWhenNoPID() {
        let session = Session.mock(id: "abc-123")
        XCTAssertEqual(session.id, "abc-123")
    }

    func testDecodesPidStartTime() throws {
        let json = """
        {
            "session_id": "pid-test",
            "project_path": "/tmp",
            "project_name": "test",
            "branch": "main",
            "status": "idle",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"},
            "pid": 9999,
            "pid_start_time": 1707400000.123
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.pid, 9999)
        XCTAssertEqual(session.pidStartTime!, 1707400000.123, accuracy: 0.001)
    }

    func testDecodesWithoutPidStartTime() throws {
        let json = """
        {
            "session_id": "old-format",
            "project_path": "/tmp",
            "project_name": "test",
            "branch": "main",
            "status": "idle",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"},
            "pid": 5555
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.pid, 5555)
        XCTAssertNil(session.pidStartTime)
    }

    func testDecodesWithoutHookWriterMetadata() throws {
        let json = """
        {
            "session_id": "pre-metadata",
            "project_path": "/tmp",
            "project_name": "test",
            "branch": "main",
            "status": "idle",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"}
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertNil(session.createdByHookVersion)
        XCTAssertNil(session.lastWrittenByHookVersion)
    }

    func testEncodesHookWriterMetadata() throws {
        var session = Session.mock()
        session.createdByHookVersion = "0.16.0"
        session.lastWrittenByHookVersion = "0.16.1"

        let data = try JSONEncoder.sessionEncoder.encode(session)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["created_by_hook_version"] as? String, "0.16.0")
        XCTAssertEqual(object["last_written_by_hook_version"] as? String, "0.16.1")
    }

    func testMarkWrittenByHookDoesNotBackfillLegacyCreator() {
        var session = Session.mock()
        session.markWrittenByHook(version: "0.16.0", isNewSessionFile: false)

        XCTAssertNil(session.createdByHookVersion)
        XCTAssertEqual(session.lastWrittenByHookVersion, "0.16.0")
    }

    func testMarkWrittenByHookStampsNewSessionCreator() {
        var session = Session.mock()
        session.markWrittenByHook(version: "0.16.0", isNewSessionFile: true)

        XCTAssertEqual(session.createdByHookVersion, "0.16.0")
        XCTAssertEqual(session.lastWrittenByHookVersion, "0.16.0")
    }

    func testDecodesDisconnectedAt() throws {
        let json = """
        {
            "session_id": "desktop-disconnected",
            "project_path": "/tmp",
            "project_name": "test",
            "branch": "main",
            "status": "idle",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "", "bundle_id": "com.anthropic.claudefordesktop"},
            "disconnected_at": "2026-02-08T12:05:00Z"
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(
            session.disconnectedAt,
            ISO8601DateFormatter().date(from: "2026-02-08T12:05:00Z")
        )
    }

    func testEncodesDisconnectedAt() throws {
        let disconnectedAt = ISO8601DateFormatter().date(from: "2026-02-08T12:05:00Z")!
        var session = Session.mock(terminal: TerminalInfo(bundleId: HostAppBundleID.claudeDesktop))
        session.disconnectedAt = disconnectedAt

        let data = try JSONEncoder.sessionEncoder.encode(session)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["disconnected_at"] as? String, "2026-02-08T12:05:00.000Z")
    }

    func testProcessStartTimeReturnsValueForCurrentProcess() {
        let pid = UInt32(getpid())
        let startTime = Session.processStartTime(pid: pid)
        XCTAssertNotNil(startTime, "Should get start time for current process")
        XCTAssertGreaterThan(startTime ?? 0, 0)
    }

    func testDecodesWorkspaceFile() throws {
        let json = """
        {
            "session_id": "ws-1",
            "project_path": "/Users/test/projects/myapp",
            "project_name": "myapp",
            "branch": "main",
            "status": "working",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"},
            "workspace_file": "/Users/test/projects/myapp/myapp.code-workspace"
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.workspaceFile, "/Users/test/projects/myapp/myapp.code-workspace")
    }

    func testDecodesWithoutWorkspaceFile() throws {
        let json = """
        {
            "session_id": "no-ws",
            "project_path": "/tmp",
            "project_name": "test",
            "branch": "main",
            "status": "idle",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"}
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertNil(session.workspaceFile)
    }

    // MARK: - Source field

    func testDecodesOpenCodeSessionJSON() throws {
        let json = """
        {
            "session_id": "oc-session-1",
            "project_path": "/Users/dev/api-server",
            "project_name": "api-server",
            "branch": "main",
            "status": "working",
            "last_prompt": "Fix the timeout bug",
            "last_activity": "2026-02-14T12:00:00.500Z",
            "started_at": "2026-02-14T11:00:00Z",
            "terminal": {"program": "iTerm2", "session_id": "w0t0p0:ABC-123", "tty": "/dev/ttys003"},
            "pid": 54321,
            "pid_start_time": null,
            "last_tool": "Bash",
            "last_tool_detail": "go test ./...",
            "notification_message": null,
            "session_name": null,
            "workspace_file": null,
            "source": "opencode"
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))

        XCTAssertEqual(session.sessionId, "oc-session-1")
        XCTAssertEqual(session.projectName, "api-server")
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(session.source, "opencode")
        XCTAssertEqual(session.agentBadge.label, "OC")
        XCTAssertEqual(session.pid, 54321)
        XCTAssertNil(session.pidStartTime)
    }

    func testDecodesWithoutSourceField() throws {
        let json = """
        {
            "session_id": "cc-session",
            "project_path": "/tmp",
            "project_name": "test",
            "branch": "main",
            "status": "idle",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"}
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertNil(session.source)
        XCTAssertEqual(session.agentBadge.label, "CC")
    }

    func testAgentBadgeLabelOpencode() {
        let session = Session.mock(source: "opencode")
        XCTAssertEqual(session.agentBadge.label, "OC")
    }

    func testAgentBadgeLabelDefault() {
        let session = Session.mock()
        XCTAssertEqual(session.agentBadge.label, "CC")
    }

    func testAgentBadgeLabelPi() {
        let session = Session.mock(source: "pi")
        XCTAssertEqual(session.agentBadge.label, "Pi")
    }

    func testAgentBadgeLabelUnknownValue() {
        let session = Session.mock(source: "aider")
        XCTAssertEqual(session.agentBadge.label, "CC")
    }

    func testSourceCarriedInWithSessionId() {
        let session = Session.mock(source: "opencode")
        let carried = session.withSessionId("new-id")
        XCTAssertEqual(carried.source, "opencode")
        XCTAssertEqual(carried.sessionId, "new-id")
    }

    // MARK: - Case-insensitive tool display

    func testContextLineLowercaseToolName() {
        let session = Session.mock(status: .working, lastTool: "bash", lastToolDetail: "go test ./...")
        XCTAssertEqual(session.contextLine, "Running: go test ./...")
    }

    func testContextLineLowercaseEdit() {
        let session = Session.mock(status: .working, lastTool: "edit", lastToolDetail: "/src/main.go")
        XCTAssertEqual(session.contextLine, "Editing main.go")
    }

    func testContextLineLowercaseRead() {
        let session = Session.mock(status: .working, lastTool: "read", lastToolDetail: "/src/config.ts")
        XCTAssertEqual(session.contextLine, "Reading config.ts")
    }

    func testOldJsonWithContextCompactedStillDecodes() throws {
        let json = """
        {
            "session_id": "old-session",
            "project_path": "/tmp",
            "project_name": "test",
            "branch": "main",
            "status": "working",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"},
            "context_compacted": true
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.sessionId, "old-session")
        XCTAssertEqual(session.status, .working)
    }

    // MARK: - Host classification (Phase 1, file-local, bundle-id only)

    func testHostClassClaudeDesktopIsDesktop() {
        let session = Session.mock(terminal: TerminalInfo(bundleId: "com.anthropic.claudefordesktop"))
        XCTAssertEqual(session.hostClass, .desktop)
    }

    func testHostClassCodexDesktopIsDesktop() {
        let session = Session.mock(terminal: TerminalInfo(bundleId: "com.openai.codex"))
        XCTAssertEqual(session.hostClass, .desktop)
    }

    func testHostClassOpencodeIgnoresLeakedCodexDesktopBundle() {
        let session = Session.mock(
            terminal: TerminalInfo(bundleId: "com.openai.codex"),
            source: "opencode"
        )
        XCTAssertEqual(session.hostClass, .ambiguous)
        XCTAssertFalse(session.isHostedByDesktopApp)
        XCTAssertFalse(session.isCodexDesktopHost)
    }

    func testHostClassPiIgnoresLeakedClaudeDesktopBundle() {
        let session = Session.mock(
            terminal: TerminalInfo(bundleId: "com.anthropic.claudefordesktop"),
            source: "pi"
        )
        XCTAssertEqual(session.hostClass, .ambiguous)
        XCTAssertFalse(session.isHostedByDesktopApp)
        XCTAssertFalse(session.isClaudeDesktopHost)
    }

    func testHostClassITerm2IsTerminal() {
        let session = Session.mock(terminal: TerminalInfo(bundleId: "com.googlecode.iterm2"))
        XCTAssertEqual(session.hostClass, .terminal)
    }

    func testHostClassVSCodeIsTerminal() {
        let session = Session.mock(terminal: TerminalInfo(bundleId: "com.microsoft.VSCode"))
        XCTAssertEqual(session.hostClass, .terminal)
    }

    func testHostClassNilTerminalIsAmbiguous() {
        let session = Session.mock(terminal: nil)
        XCTAssertEqual(session.hostClass, .ambiguous)
    }

    func testHostClassMissingBundleIdIsAmbiguous() {
        let session = Session.mock(terminal: TerminalInfo(program: "weird-term"))
        XCTAssertEqual(session.hostClass, .ambiguous)
    }

    func testHostClassEmptyBundleIdIsAmbiguous() {
        let session = Session.mock(terminal: TerminalInfo(bundleId: ""))
        XCTAssertEqual(session.hostClass, .ambiguous)
    }

    func testHostClassUnknownBundleIdIsAmbiguous() {
        let session = Session.mock(terminal: TerminalInfo(bundleId: "com.example.unknownterm"))
        XCTAssertEqual(session.hostClass, .ambiguous)
    }

    // `source` must NEVER classify: it cannot tell desktop from CLI.
    func testHostClassSourceCodexWithoutBundleIdIsAmbiguous() {
        let session = Session.mock(terminal: nil, source: "codex")
        XCTAssertEqual(session.hostClass, .ambiguous)
    }

    func testHostClassSourceCcWithoutBundleIdIsAmbiguous() {
        let session = Session.mock(terminal: nil, source: "cc")
        XCTAssertEqual(session.hostClass, .ambiguous)
    }

    // bundle id wins over source: Codex CLI running inside iTerm2 is terminal.
    func testHostClassCodexCliInTerminalIsTerminal() {
        let session = Session.mock(terminal: TerminalInfo(bundleId: "com.googlecode.iterm2"), source: "codex")
        XCTAssertEqual(session.hostClass, .terminal)
    }

    // Desktop bundle id takes precedence over a (contrived) multiplexer.
    func testHostClassDesktopBundleIdWinsOverMultiplexer() {
        let term = TerminalInfo(bundleId: "com.anthropic.claudefordesktop",
                                multiplexer: .tmux(socket: "/tmp/s", paneId: "%1", binaryPath: nil))
        XCTAssertEqual(Session.mock(terminal: term).hostClass, .desktop)
    }

    // A multiplexer is hard terminal evidence (desktop is returned first, so this can't be desktop).
    func testHostClassTmuxWithoutBundleIdIsTerminal() {
        let term = TerminalInfo(multiplexer: .tmux(socket: "/tmp/s", paneId: "%1", binaryPath: nil))
        XCTAssertEqual(Session.mock(terminal: term).hostClass, .terminal)
    }

    func testHostClassZellijWithoutBundleIdIsTerminal() {
        let term = TerminalInfo(multiplexer: .zellij(sessionName: "main", paneId: "0", binaryPath: nil))
        XCTAssertEqual(Session.mock(terminal: term).hostClass, .terminal)
    }

    // tty alone is NOT hard evidence — it can be env-copied (env["TTY"]) and inherited by GUI children.
    func testHostClassTtyOnlyIsAmbiguous() {
        let term = TerminalInfo(tty: "/dev/ttys003")
        XCTAssertEqual(Session.mock(terminal: term).hostClass, .ambiguous)
    }

    // program name alone is env-only and leaks to GUI children → must not classify terminal.
    func testHostClassProgramOnlyIsAmbiguous() {
        let term = TerminalInfo(program: "iTerm.app")
        XCTAssertEqual(Session.mock(terminal: term).hostClass, .ambiguous)
    }

    // MARK: - Transient lifecycle field

    // Decoding a normal session file leaves lifecycle at its default (never persisted).
    func testDecodeDefaultsLifecycleToActive() throws {
        let json = """
        {
            "session_id": "life-1", "project_path": "/tmp", "project_name": "test",
            "branch": "main", "status": "idle",
            "last_activity": "2026-02-08T12:00:00Z", "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"}
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.lifecycle, .active)
    }

    // The transient field participates in Equatable, so a dormant flip re-renders the card.
    func testLifecycleParticipatesInEquatable() {
        let base = Session.mock(id: "life-eq")
        var dormant = base
        dormant.lifecycle = .dormant
        XCTAssertNotEqual(base, dormant)
        XCTAssertEqual(base.lifecycle, .active)
    }
}
