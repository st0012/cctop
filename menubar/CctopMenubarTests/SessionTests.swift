import XCTest
import UserNotifications
@testable import CctopMenubar

final class SessionTests: XCTestCase {
    private let notificationTestCctopSessionID = "11111111-1111-4111-8111-111111111111"

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
        XCTAssertNil(session.cctopSessionId)
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

    func testContextLineNeedsAttentionFallsBackToNeedsAttention() {
        let session = Session.mock(status: .needsAttention)
        XCTAssertEqual(session.contextLine, "Needs attention")
    }

    func testContextLineCompacting() {
        let session = Session.mock(status: .compacting)
        XCTAssertEqual(session.contextLine, "Compacting context...")
    }

    func testNotificationContentPrefixesDistinctSessionTitleWithProject() {
        let session = Session.mock(
            project: "cctop",
            sessionName: "Handle notification permission flow",
            status: .waitingInput,
            lastPrompt: "New comment. Keep the loop until there's a thumb up on pr description",
            source: "codex"
        )

        XCTAssertEqual(session.notificationContent.title, "[cctop] Handle notification permission flow")
        XCTAssertEqual(session.notificationContent.subtitle, "Codex is waiting for input")
        XCTAssertEqual(
            session.notificationContent.body,
            "New comment. Keep the loop until there's a thumb up on pr description"
        )
    }

    func testNotificationContentDoesNotDuplicateProjectTitle() {
        let session = Session.mock(
            project: "cctop",
            status: .waitingInput,
            lastPrompt: "How can I watch it",
            source: "cc"
        )

        XCTAssertEqual(session.notificationContent.title, "cctop")
        XCTAssertEqual(session.notificationContent.subtitle, "Claude is waiting for input")
        XCTAssertEqual(session.notificationContent.body, "How can I watch it")
    }

    func testNotificationContentUsesDesktopProjectPrefix() {
        let session = Session.mock(
            project: "generated-worktree",
            sessionName: "Handle notification permission flow",
            status: .waitingPermission,
            notificationMessage: "Allow Bash: make all",
            terminal: TerminalInfo(bundleId: HostAppBundleID.codexDesktop),
            source: "codex",
            desktopProjectName: "cctop"
        )

        XCTAssertEqual(session.notificationContent.title, "[cctop] Handle notification permission flow")
        XCTAssertEqual(session.notificationContent.subtitle, "Codex Desktop needs permission")
        XCTAssertEqual(session.notificationContent.body, "Allow Bash: make all")
    }

    func testNotificationContentPrefixesTitleStartingWithProjectName() {
        let session = Session.mock(
            project: "optimistic-mestorf-1d360b",
            sessionName: "CCTOP promotional video",
            status: .waitingInput,
            lastPrompt: "How can I watch it",
            terminal: TerminalInfo(bundleId: HostAppBundleID.claudeDesktop),
            source: "cc",
            desktopProjectName: "cctop"
        )

        XCTAssertEqual(session.notificationContent.title, "[cctop] cctop promotional video")
        XCTAssertEqual(session.notificationContent.subtitle, "Claude Desktop is waiting for input")
    }

    func testNotificationContentCleansAndTruncatesBody() {
        let session = Session.mock(
            project: "rdoc",
            sessionName: "Identify RDoc plugin incompatibility",
            status: .waitingInput,
            lastPrompt: "First line\n\nSecond line with extra spacing that keeps going beyond the banner width",
            source: "codex"
        )

        XCTAssertEqual(
            session.notificationContent.body,
            "First line Second line with extra spacing that keeps going beyond the..."
        )
    }

    func testNotificationBodyPreservesUserTextCasing() {
        let session = Session.mock(
            project: "cctop",
            sessionName: "Brand wording",
            status: .waitingInput,
            lastPrompt: "Should the body keep CCTOP uppercase?",
            source: "codex"
        )

        XCTAssertEqual(session.notificationContent.title, "[cctop] Brand wording")
        XCTAssertEqual(session.notificationContent.body, "Should the body keep CCTOP uppercase?")
    }

    func testNotificationBodyPrefersNotificationMessageForWaitingInput() {
        let session = Session.mock(
            project: "cctop",
            sessionName: "Elicitation dialog",
            status: .waitingInput,
            lastPrompt: "Actual user prompt",
            notificationMessage: "Which option should I choose?",
            source: "codex"
        )

        XCTAssertEqual(session.notificationContent.body, "Which option should I choose?")
    }

    func testNotificationBodyPreservesMachineLikeNotificationMessage() {
        let session = Session.mock(
            project: "cctop",
            sessionName: "Elicitation dialog",
            status: .waitingInput,
            lastPrompt: "<heartbeat><automation_id>watchdog</automation_id></heartbeat>",
            notificationMessage: "# Files: choose the changelog section",
            source: "codex"
        )

        XCTAssertEqual(session.notificationContent.body, "# Files: choose the changelog section")
    }

    func testNotificationBodyFallsBackToLastPromptForWaitingInput() {
        let session = Session.mock(
            project: "cctop",
            sessionName: "Generic idle prompt",
            status: .waitingInput,
            lastPrompt: "Actual user prompt",
            source: "codex"
        )

        XCTAssertEqual(session.notificationContent.body, "Actual user prompt")
    }

    func testNotificationBodyPreservesNonCodexPromptFallback() {
        let session = Session.mock(
            project: "cctop",
            sessionName: "Generic idle prompt",
            status: .waitingInput,
            lastPrompt: "# Files: draft a changelog",
            source: "cc"
        )

        XCTAssertEqual(session.notificationContent.body, "# Files: draft a changelog")
    }

    func testNotificationBodyPreservesCodexPromptFallbackStartingWithScaffoldHeading() {
        let session = Session.mock(
            project: "cctop",
            sessionName: "Generic idle prompt",
            status: .waitingInput,
            lastPrompt: "# Files: draft a changelog",
            source: "codex"
        )

        XCTAssertEqual(session.notificationContent.body, "# Files: draft a changelog")
    }

    func testNotificationBodyExtractsUserRequestFromCodexScaffold() {
        let session = Session.mock(
            project: "cctop",
            sessionName: "Chief driver",
            status: .waitingInput,
            lastPrompt: """
            # In app browser:
            - Current URL: file:///tmp/codex-explainers/example.html

            ## My request for Codex:
            This is a separate thing, not related to the current PR.
            """,
            source: "codex"
        )

        XCTAssertEqual(
            session.notificationContent.body,
            "This is a separate thing, not related to the current PR."
        )
    }

    func testNotificationBodyFallsBackForMachineOnlyCodexScaffoldWithMultipleSections() {
        let session = Session.mock(
            project: "cctop",
            sessionName: "Generated context",
            status: .waitingInput,
            lastPrompt: """
            # Files:
            - /Users/test/project/App.swift

            # In app browser:
            - Current URL: http://localhost:3000
            """,
            source: "codex"
        )

        XCTAssertEqual(session.notificationContent.body, "Waiting for input")
    }

    func testNotificationBodyFallsBackForMachineWrapperPrompts() {
        let heartbeat = Session.mock(
            project: "cctop",
            sessionName: "Chief watchdog",
            status: .waitingInput,
            lastPrompt: """
            <heartbeat>
              <automation_id>cctop-chief-workflow-watchdog</automation_id>
            </heartbeat>
            """,
            source: "codex"
        )
        let delegation = Session.mock(
            project: "cctop",
            sessionName: "Driver task",
            status: .waitingInput,
            lastPrompt: """
            &lt;codex_delegation&gt;
              &lt;source_thread_id&gt;019f3cfa&lt;/source_thread_id&gt;
            &lt;/codex_delegation&gt;
            """,
            source: "codex"
        )

        XCTAssertEqual(heartbeat.notificationContent.body, "Waiting for input")
        XCTAssertEqual(delegation.notificationContent.body, "Waiting for input")
    }

    func testNotificationBodyFallsBackForLegacyCodexDesktopMachineWrapperPrompts() {
        let session = Session.mock(
            project: "cctop",
            sessionName: "Chief watchdog",
            status: .waitingInput,
            lastPrompt: """
            <heartbeat>
              <automation_id>cctop-chief-workflow-watchdog</automation_id>
            </heartbeat>
            """,
            terminal: TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        )

        XCTAssertEqual(session.notificationContent.body, "Waiting for input")
    }

    func testNotificationBodyRejectsMachineWrapperBeforeExtractingCodexMarker() {
        let session = Session.mock(
            project: "cctop",
            sessionName: "Driver task",
            status: .waitingInput,
            lastPrompt: """
            <codex_delegation>
              <input>
            ## My request for Codex:
            Please fix notification text.
              </input>
            </codex_delegation>
            """,
            source: "codex"
        )

        XCTAssertEqual(session.notificationContent.body, "Waiting for input")
    }

    func testNotificationBodyDoesNotExtractCodexMarkerFromOrdinaryPrompt() {
        let session = Session.mock(
            project: "cctop",
            sessionName: "Docs edit",
            status: .waitingInput,
            lastPrompt: """
            Please edit this template section:
            ## My request for Codex:
            Keep the heading visible.
            """,
            source: "codex"
        )

        XCTAssertEqual(
            session.notificationContent.body,
            "Please edit this template section: ## My request for Codex: Keep the..."
        )
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

    func testDecodesDesktopProjectName() throws {
        let json = """
        {
            "session_id": "desktop-project-1",
            "project_path": "/private/var/folders/codex-worktree",
            "project_name": "codex-worktree",
            "desktop_project_name": "cctop",
            "branch": "main",
            "status": "working",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "", "bundle_id": "com.openai.codex"},
            "source": "codex"
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.desktopProjectName, "cctop")
        XCTAssertEqual(session.displayName, "codex-worktree")
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

    func testIdentifiableIDUsesHarnessSpecificDisplayIdentity() {
        let cases: [(name: String, session: Session, expectedID: String)] = [
            (
                "codex conversations use session id even with a shared host pid",
                Session.mock(id: "codex-thread-1", pid: 12345, source: Session.codexSource),
                "codex-thread-1"
            ),
            (
                "non-codex sessions use pid when available",
                Session.mock(id: "claude-thread-1", pid: 12345, source: Session.ccSource),
                "12345"
            ),
            (
                "non-codex sessions fall back to session id when pid is missing",
                Session.mock(id: "claude-thread-2", source: Session.ccSource),
                "claude-thread-2"
            ),
        ]

        for identityCase in cases {
            XCTAssertEqual(identityCase.session.id, identityCase.expectedID, identityCase.name)
        }
    }

    // MARK: - Notification identity

    func testNotificationUserInfoStoresOnlyPermanentCctopSessionID() throws {
        let cctopSessionID = "11111111-1111-4111-8111-111111111111"

        let userInfo = try XCTUnwrap(
            SessionIdentityPolicy.notificationUserInfo(forCctopSessionID: cctopSessionID)
        )

        XCTAssertEqual(
            userInfo[SessionIdentityPolicy.notificationCctopSessionIDKey] as? String,
            cctopSessionID
        )
        XCTAssertNil(userInfo[SessionIdentityPolicy.notificationSessionIDKey])
        XCTAssertNil(userInfo[SessionIdentityPolicy.notificationSessionPIDKey])
        XCTAssertNil(SessionIdentityPolicy.notificationUserInfo(forCctopSessionID: "not-a-uuid"))
    }

    func testNotificationMetadataFindsPriorProcessObservationByPermanentIdentity() throws {
        let sharedID = "11111111-1111-4111-8111-111111111111"
        let oldObservation = Session.mock(
            id: "old-process", cctopSessionId: sharedID,
            status: .waitingPermission, pid: 11_111, source: Session.opencodeSource
        )
        let currentObservation = Session.mock(
            id: "new-process", cctopSessionId: sharedID,
            status: .waitingPermission, pid: 22_222, source: Session.opencodeSource
        )
        let unrelated = Session.mock(
            id: "unrelated", cctopSessionId: "22222222-2222-4222-8222-222222222222",
            status: .waitingPermission, pid: 33_333, source: Session.opencodeSource
        )
        let oldRequest = try XCTUnwrap(SessionManager.notificationRequest(for: oldObservation))
        let currentRequest = try XCTUnwrap(SessionManager.notificationRequest(for: currentObservation))
        let unrelatedRequest = try XCTUnwrap(SessionManager.notificationRequest(for: unrelated))
        let preMigrationContent = UNMutableNotificationContent()
        preMigrationContent.userInfo = [
            SessionIdentityPolicy.notificationCctopSessionIDKey: sharedID,
            SessionIdentityPolicy.notificationSessionIDKey: oldObservation.sessionId,
            SessionIdentityPolicy.notificationSessionPIDKey: String(try XCTUnwrap(oldObservation.pid)),
        ]
        let preMigrationRequest = UNNotificationRequest(
            identifier: "session-active:\(oldObservation.id)",
            content: preMigrationContent,
            trigger: nil
        )
        let malformedContent = UNMutableNotificationContent()
        malformedContent.userInfo = [SessionIdentityPolicy.notificationCctopSessionIDKey: "not-a-uuid"]
        let malformedRequest = UNNotificationRequest(identifier: "malformed", content: malformedContent, trigger: nil)
        let missingRequest = UNNotificationRequest(
            identifier: "missing", content: UNMutableNotificationContent(), trigger: nil
        )

        XCTAssertEqual(oldRequest.identifier, currentRequest.identifier)
        XCTAssertEqual(oldRequest.content.userInfo as NSDictionary, currentRequest.content.userInfo as NSDictionary)
        XCTAssertEqual(
            SessionNotificationClient.identifiers(
                belongingTo: sharedID,
                in: [preMigrationRequest, oldRequest, currentRequest, unrelatedRequest, malformedRequest, missingRequest]
            ),
            [preMigrationRequest.identifier]
        )
    }

    func testNotificationPayloadPermanentIDOverridesStaleLegacyFields() {
        let firstID = "11111111-1111-4111-8111-111111111111"
        let secondID = "22222222-2222-4222-8222-222222222222"
        let first = Session.mock(id: "codex-thread-1", cctopSessionId: firstID, pid: 12345, source: "codex")
        let second = Session.mock(id: "codex-thread-2", cctopSessionId: secondID, pid: 12345, source: "codex")
        let userInfo: [AnyHashable: Any] = [
            SessionIdentityPolicy.notificationCctopSessionIDKey: secondID,
            SessionIdentityPolicy.notificationSessionIDKey: "codex-thread-1",
            SessionIdentityPolicy.notificationSessionPIDKey: "12345",
        ]

        let resolvedID = SessionIdentityPolicy.notificationCctopSessionID(
            matchingNotificationUserInfo: userInfo,
            in: [first, second]
        )

        XCTAssertEqual(resolvedID, secondID)
    }

    func testNotificationPayloadWithMalformedPermanentIDDoesNotFallBack() {
        let session = Session.mock(id: "codex-thread-1", pid: 12345, source: "codex")
        let userInfo: [AnyHashable: Any] = [
            SessionIdentityPolicy.notificationCctopSessionIDKey: "not-a-uuid",
            SessionIdentityPolicy.notificationSessionIDKey: "codex-thread-1",
            SessionIdentityPolicy.notificationSessionPIDKey: "12345",
        ]

        let resolvedID = SessionIdentityPolicy.notificationCctopSessionID(
            matchingNotificationUserInfo: userInfo,
            in: [session]
        )

        XCTAssertNil(resolvedID)
    }

    func testLegacyNotificationPayloadRecoversOnePermanentLogicalID() {
        let cctopSessionID = "11111111-1111-4111-8111-111111111111"
        let currentObservation = Session.mock(
            id: "codex-thread-1", cctopSessionId: cctopSessionID, pid: 67890, source: "codex"
        )
        let userInfo: [AnyHashable: Any] = [
            SessionIdentityPolicy.notificationSessionIDKey: "codex-thread-1",
            SessionIdentityPolicy.notificationSessionPIDKey: "99999",
        ]

        let resolvedID = SessionIdentityPolicy.notificationCctopSessionID(
            matchingNotificationUserInfo: userInfo,
            in: [currentObservation]
        )

        XCTAssertEqual(resolvedID, cctopSessionID)
    }

    func testLegacyNotificationPayloadFailsClosedForAmbiguousPermanentIdentity() {
        let first = Session.mock(
            id: "codex-thread-1", cctopSessionId: "11111111-1111-4111-8111-111111111111",
            pid: 12_345, source: Session.codexSource
        )
        let second = Session.mock(
            id: "codex-thread-1", cctopSessionId: "22222222-2222-4222-8222-222222222222",
            pid: 67_890, source: Session.codexSource
        )

        XCTAssertNil(
            SessionIdentityPolicy.notificationCctopSessionID(
                matchingNotificationUserInfo: [SessionIdentityPolicy.notificationSessionIDKey: "codex-thread-1"],
                in: [first, second]
            )
        )
    }

    func testLegacyNotificationSessionIDMissDoesNotFallThroughToPID() {
        let session = Session.mock(
            id: "current-session", cctopSessionId: "11111111-1111-4111-8111-111111111111",
            pid: 12345, source: Session.opencodeSource
        )
        let userInfo: [AnyHashable: Any] = [
            SessionIdentityPolicy.notificationSessionIDKey: "stale-session",
            SessionIdentityPolicy.notificationSessionPIDKey: "12345",
        ]

        XCTAssertNil(
            SessionIdentityPolicy.notificationCctopSessionID(
                matchingNotificationUserInfo: userInfo,
                in: [session]
            )
        )
    }

    func testLegacyNotificationPayloadFailsClosedForUniquePID() {
        let session = Session.mock(
            id: "current-process", cctopSessionId: "11111111-1111-4111-8111-111111111111",
            pid: 12345, source: Session.opencodeSource
        )
        let userInfo: [AnyHashable: Any] = [
            SessionIdentityPolicy.notificationSessionPIDKey: "12345",
        ]

        XCTAssertNil(
            SessionIdentityPolicy.notificationCctopSessionID(
                matchingNotificationUserInfo: userInfo,
                in: [session]
            )
        )
    }

    func testLegacyNotificationPayloadFailsClosedForProcessSessionID() {
        let session = Session.mock(
            id: "12345", cctopSessionId: "11111111-1111-4111-8111-111111111111",
            pid: 12345, source: Session.opencodeSource
        )
        let userInfo: [AnyHashable: Any] = [
            SessionIdentityPolicy.notificationSessionIDKey: "12345",
        ]

        XCTAssertNil(
            SessionIdentityPolicy.notificationCctopSessionID(
                matchingNotificationUserInfo: userInfo,
                in: [session]
            )
        )
    }

    func testNotificationRequestIdentifierUsesOnlyPermanentIdentity() {
        let cctopSessionID = "11111111-1111-4111-8111-111111111111"
        XCTAssertEqual(
            SessionIdentityPolicy.notificationRequestIdentifier(forCctopSessionID: cctopSessionID),
            "session-\(cctopSessionID)"
        )
        XCTAssertNil(SessionIdentityPolicy.notificationRequestIdentifier(forCctopSessionID: "not-a-uuid"))
    }

    func testManualSessionVisibilityPersistsOnlySortedCctopSessionIDs() throws {
        let suiteName = "cctop-manual-visibility-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ManualSessionVisibilityStore(defaults: defaults)

        var terminal = Session(
            sessionId: "private-terminal-conversation",
            projectPath: "/private/project/path",
            branch: "secret-branch",
            terminal: TerminalInfo()
        )
        terminal.cctopSessionId = "11111111-1111-4111-8111-111111111111"
        terminal.pid = 42
        terminal.sessionName = "Private session title"
        let codex = Session.mock(
            id: "codex-thread",
            cctopSessionId: "22222222-2222-4222-8222-222222222222",
            source: Session.codexSource
        )

        store.hide(terminal)
        store.hide(codex)

        let stored = try XCTUnwrap(defaults.stringArray(forKey: ManualSessionVisibilityStore.defaultsKey))
        XCTAssertEqual(stored, [
            "11111111-1111-4111-8111-111111111111",
            "22222222-2222-4222-8222-222222222222",
        ])
        let payload = stored.joined(separator: "\n")
        XCTAssertFalse(payload.contains("active:42"))
        XCTAssertFalse(payload.contains(terminal.sessionName!))
        XCTAssertFalse(payload.contains(terminal.projectPath))
        XCTAssertFalse(payload.contains(terminal.branch))
    }

    func testManualSessionVisibilityPrunesOnlyMissingCctopSessionIDs() {
        let suiteName = "cctop-manual-visibility-prune-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ManualSessionVisibilityStore(defaults: defaults)
        let first = Session.mock(
            id: "first", cctopSessionId: "11111111-1111-4111-8111-111111111111"
        )
        let secondID = "22222222-2222-4222-8222-222222222222"
        let second = Session.mock(id: "second", cctopSessionId: secondID)

        store.hide(first)
        store.hide(second)
        store.prune(retaining: [secondID])

        XCTAssertEqual(store.hiddenSessionIDs, [secondID])
    }

    func testManualSessionVisibilityMigratesOnlyExactDurableLegacyKeys() {
        let suiteName = "cctop-manual-visibility-legacy-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let codexID = "11111111-1111-4111-8111-111111111111"
        let desktopID = "22222222-2222-4222-8222-222222222222"
        let activeID = "33333333-3333-4333-8333-333333333333"
        defaults.set(
            ["active:42", "codex:durable-codex", "codex:missing", "desktop:durable-desktop"],
            forKey: ManualSessionVisibilityStore.legacyDefaultsKey
        )
        let store = ManualSessionVisibilityStore(defaults: defaults)
        let codex = Session.mock(id: "durable-codex", cctopSessionId: codexID, source: Session.codexSource)
        let desktop = Session.mock(
            id: "durable-desktop",
            cctopSessionId: desktopID,
            terminal: TerminalInfo(bundleId: HostAppBundleID.claudeDesktop),
            source: Session.ccSource
        )
        let active = Session.mock(id: "terminal", cctopSessionId: activeID, pid: 42, source: Session.ccSource)
        var unstampedCodex = codex
        unstampedCodex.cctopSessionId = nil

        let partialIDs = store.migrateLegacyStableKeys(
            using: [codex, desktop, active],
            persistedSessions: [unstampedCodex, desktop, active],
            inventoryComplete: false
        )

        XCTAssertEqual(partialIDs, [codexID, desktopID])
        XCTAssertEqual(store.hiddenSessionIDs, [codexID, desktopID])
        XCTAssertEqual(
            store.unresolvedDurableLegacyKeys,
            ["codex:durable-codex", "codex:missing", "desktop:durable-desktop"]
        )
        XCTAssertEqual(
            defaults.stringArray(forKey: ManualSessionVisibilityStore.legacyDefaultsKey),
            ["active:42", "codex:durable-codex", "codex:missing", "desktop:durable-desktop"]
        )

        let completeIDs = store.migrateLegacyStableKeys(
            using: [codex, desktop, active],
            persistedSessions: [unstampedCodex, desktop, active],
            inventoryComplete: true
        )

        XCTAssertEqual(completeIDs, [codexID, desktopID])
        XCTAssertEqual(store.unresolvedDurableLegacyKeys, ["codex:durable-codex"])
        XCTAssertEqual(
            defaults.stringArray(forKey: ManualSessionVisibilityStore.legacyDefaultsKey),
            ["codex:durable-codex"]
        )

        let confirmedIDs = store.migrateLegacyStableKeys(
            using: [codex, desktop, active],
            persistedSessions: [codex, desktop, active],
            inventoryComplete: true
        )

        XCTAssertEqual(confirmedIDs, [codexID, desktopID])
        XCTAssertTrue(store.unresolvedDurableLegacyKeys.isEmpty)
        XCTAssertNil(defaults.object(forKey: ManualSessionVisibilityStore.legacyDefaultsKey))
    }

    func testLegacyManualHideEvidenceAcceptsOnlyCanonicalSupportedUUIDKeys() {
        let sessionID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let lowercaseID = sessionID.lowercased()

        XCTAssertEqual(
            ManualSessionVisibilityStore.durableEvidence(forLegacyKey: "codex:\(sessionID)"),
            "codex:\(lowercaseID)"
        )
        XCTAssertEqual(
            ManualSessionVisibilityStore.durableEvidence(forLegacyKey: "desktop:\(sessionID)"),
            "cc:\(lowercaseID)"
        )
        for key in ["active:\(sessionID)", "cc:\(sessionID)", "codex:not-a-uuid", "desktop:\(sessionID.replacingOccurrences(of: "-", with: ""))"] {
            XCTAssertNil(ManualSessionVisibilityStore.durableEvidence(forLegacyKey: key))
        }
    }

    func testManualSessionVisibilityRetainsAmbiguousLegacyKey() {
        let suiteName = "cctop-manual-visibility-ambiguous-legacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let threadID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let legacyKey = "codex:\(threadID)"
        defaults.set([legacyKey], forKey: ManualSessionVisibilityStore.legacyDefaultsKey)
        let store = ManualSessionVisibilityStore(defaults: defaults)
        let firstID = "11111111-1111-4111-8111-111111111111"
        let secondID = "22222222-2222-4222-8222-222222222222"
        var legacy = Session.mock(id: threadID, harnessSessionId: threadID, source: Session.codexSource)
        legacy.cctopSessionId = nil
        let unresolvedIDs = store.migrateLegacyStableKeys(
            using: [legacy],
            persistedSessions: [legacy],
            inventoryComplete: true
        )

        XCTAssertTrue(unresolvedIDs.isEmpty)
        XCTAssertTrue(store.hiddenSessionIDs.isEmpty)
        XCTAssertEqual(store.unresolvedDurableLegacyKeys, [legacyKey])

        let first = Session.mock(
            id: "first-observation",
            cctopSessionId: firstID,
            harnessSessionId: threadID,
            source: Session.codexSource
        )
        let second = Session.mock(
            id: "second-observation",
            cctopSessionId: secondID,
            harnessSessionId: threadID,
            source: Session.codexSource
        )
        let ambiguousIDs = store.migrateLegacyStableKeys(
            using: [legacy, first, second],
            persistedSessions: [legacy, first, second],
            inventoryComplete: true
        )

        XCTAssertTrue(ambiguousIDs.isEmpty)
        XCTAssertTrue(store.hiddenSessionIDs.isEmpty)
        XCTAssertEqual(store.unresolvedDurableLegacyKeys, [legacyKey])
    }

    func testManualSessionVisibilityIgnoresRowsWithoutPermanentIdentity() {
        let suiteName = "cctop-manual-visibility-legacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ManualSessionVisibilityStore(defaults: defaults)
        var legacy = Session.mock(id: "legacy")
        legacy.cctopSessionId = nil

        store.hide(legacy)

        XCTAssertFalse(store.isHidden(legacy))
        XCTAssertNil(defaults.object(forKey: ManualSessionVisibilityStore.defaultsKey))
        XCTAssertNil(ManualSessionHideConfirmation(session: legacy))
    }

    func testManualSessionHideConfirmationDescribesIrreversibleVisibleEffect() throws {
        let session = Session.mock(
            id: "private-session",
            cctopSessionId: "11111111-1111-4111-8111-111111111111",
            project: "cctop",
            sessionName: "Investigate lifecycle",
            source: Session.codexSource
        )

        let confirmation = try XCTUnwrap(ManualSessionHideConfirmation(session: session))

        XCTAssertEqual(confirmation.id, "hide:11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(confirmation.title, "Hide “Investigate lifecycle” from cctop?")
        XCTAssertEqual(confirmation.primaryButtonTitle, "Hide Session")
        XCTAssertEqual(
            confirmation.message,
            "It will disappear from the panel, notifications, Navigate mode, and Stream Deck. "
                + "This does not stop or delete the underlying session; cctop will keep it available for lifecycle and Cleanup. "
                + "You cannot show it again while its local session record exists."
        )
        XCTAssertEqual(confirmation.session, session)
    }

    func testPopupConfirmationRoutesCleanupAndSessionHideWithDistinctIdentity() throws {
        let cleanupConfirmation = WorktreeRemovalConfirmation.review(
            .normalRemove(.mock(state: .review(["Worktree has untracked files"])))
        )
        let sessionConfirmation = try XCTUnwrap(ManualSessionHideConfirmation(
            session: .mock(
                id: "private-session",
                cctopSessionId: "11111111-1111-4111-8111-111111111111",
                source: Session.codexSource
            )
        ))
        let cleanupRoute = PopupConfirmation.cleanup(cleanupConfirmation)
        let sessionRoute = PopupConfirmation.sessionHide(sessionConfirmation)

        XCTAssertEqual(cleanupRoute.id, "cleanup:\(cleanupConfirmation.id)")
        XCTAssertEqual(sessionRoute.id, "session-hide:\(sessionConfirmation.id)")
        XCTAssertNotEqual(cleanupRoute.id, sessionRoute.id)
        XCTAssertEqual(cleanupRoute, .cleanup(cleanupConfirmation))
        XCTAssertEqual(sessionRoute, .sessionHide(sessionConfirmation))
        XCTAssertEqual(
            PopupView.confirmationAfterCleanupReview(cleanupConfirmation, preserving: sessionRoute),
            sessionRoute
        )
        XCTAssertEqual(
            PopupView.confirmationAfterCleanupReview(cleanupConfirmation, preserving: nil),
            cleanupRoute
        )
    }

    func testNotificationRequestDoesNotUseVisibleThreadGrouping() throws {
        let cctopSessionID = "11111111-1111-4111-8111-111111111111"
        let session = Session.mock(
            id: "claude-desktop-thread-1",
            cctopSessionId: cctopSessionID,
            pid: 12345,
            terminal: TerminalInfo(bundleId: HostAppBundleID.claudeDesktop),
            source: "cc"
        )

        let request = try XCTUnwrap(SessionManager.notificationRequest(for: session))

        XCTAssertEqual(request.identifier, "session-\(cctopSessionID)")
        XCTAssertEqual(request.content.threadIdentifier, "")
    }

    func testNotificationRequestFailsClosedWithoutPermanentIdentity() {
        var missing = Session.mock(id: "legacy", status: .waitingInput)
        missing.cctopSessionId = nil
        var malformed = missing
        malformed.cctopSessionId = "not-a-uuid"

        XCTAssertNil(SessionManager.notificationRequest(for: missing))
        XCTAssertNil(SessionManager.notificationRequest(for: malformed))
    }

    @MainActor
    func testPostNotificationReplacesOutstandingNotificationForSession() throws {
        final class Recorder {
            var events: [String] = []
        }

        let recorder = Recorder()
        var sources = SessionDataSources.live()
        sources.manualSessionVisibility = isolatedManualSessionVisibility(prefix: "cctop-replace-notification")
        let sessionsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        sources.sessionsDir = sessionsDir
        sources.notificationClient = SessionNotificationClient(
            add: { request, completion in
                recorder.events.append("add:\(request.identifier)")
                completion(nil)
            },
            removePending: { identifiers in
                recorder.events.append("removePending:\(identifiers.joined(separator: ","))")
            },
            removeDelivered: { identifiers in
                recorder.events.append("removeDelivered:\(identifiers.joined(separator: ","))")
            }
        )
        let cctopSessionID = "11111111-1111-4111-8111-111111111111"
        let session = Session.mock(
            id: "claude-desktop-thread-1",
            cctopSessionId: cctopSessionID,
            status: .waitingPermission,
            pid: 12345,
            terminal: TerminalInfo(bundleId: HostAppBundleID.claudeDesktop),
            source: "cc"
        )
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: FileManager.default.temporaryDirectory),
            dataSources: sources,
            startMonitoring: false
        )
        manager.sessions = [session]

        manager.postNotification(for: session)

        XCTAssertEqual(
            recorder.events,
            [
                "removePending:session-\(cctopSessionID)",
                "removeDelivered:session-\(cctopSessionID)",
                "add:session-\(cctopSessionID)",
            ]
        )
    }

    @MainActor
    func testPostNotificationSkipsHiddenOrVanishedSessionDuringPermissionDelay() throws {
        final class Recorder {
            var events: [String] = []
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cctop-hidden-notification-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let historyDir = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "cctop-hidden-notification-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ManualSessionVisibilityStore(defaults: defaults)
        let session = Session.mock(
            id: "hidden-attention", status: .waitingPermission,
            source: Session.codexSource
        )

        let recorder = Recorder()
        var sources = SessionDataSources.live()
        sources.sessionsDir = sessionsDir
        sources.manualSessionVisibility = store
        sources.notificationClient = SessionNotificationClient(
            add: { request, completion in
                recorder.events.append("add:\(request.identifier)")
                completion(nil)
            },
            removePending: { _ in recorder.events.append("removePending") },
            removeDelivered: { _ in recorder.events.append("removeDelivered") }
        )
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: historyDir),
            dataSources: sources,
            startMonitoring: false
        )
        var noLongerNeedsAttention = session
        noLongerNeedsAttention.status = .working
        manager.sessions = [noLongerNeedsAttention]
        manager.postNotification(for: session)

        manager.sessions = [session]
        store.hide(session)

        manager.postNotification(for: session)
        store.prune(retaining: [])
        manager.sessions = []
        manager.postNotification(for: session)

        XCTAssertEqual(recorder.events, [])
    }

    @MainActor
    func testPostNotificationDoesNotReuseLegacyPIDIdentityDuringPermissionDelay() throws {
        final class Recorder {
            var events: [String] = []
        }

        let recorder = Recorder()
        var sources = SessionDataSources.live()
        sources.manualSessionVisibility = isolatedManualSessionVisibility(prefix: "cctop-reused-pid-notification")
        let sessionsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        sources.sessionsDir = sessionsDir
        sources.notificationClient = SessionNotificationClient(
            add: { _, completion in
                recorder.events.append("add")
                completion(nil)
            },
            removePending: { _ in recorder.events.append("removePending") },
            removeDelivered: { _ in recorder.events.append("removeDelivered") }
        )
        let original = Session.mock(
            id: "reused-pid", cctopSessionId: "11111111-1111-4111-8111-111111111111",
            pid: 42_042, source: Session.ccSource
        )
        let replacement = Session.mock(
            id: "reused-pid", cctopSessionId: "22222222-2222-4222-8222-222222222222",
            pid: 42_042, source: Session.ccSource
        )
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: FileManager.default.temporaryDirectory),
            dataSources: sources,
            startMonitoring: false
        )
        manager.sessions = [replacement]

        manager.postNotification(for: original)

        XCTAssertTrue(recorder.events.isEmpty)
    }

    @MainActor
    func testPostNotificationFailsClosedWithoutPermanentIdentity() throws {
        final class Recorder {
            var events: [String] = []
        }

        let recorder = Recorder()
        var sources = try isolatedSessionDataSources(prefix: "cctop-missing-notification-identity").sources
        sources.notificationClient = SessionNotificationClient(
            add: { _, completion in
                recorder.events.append("add")
                completion(nil)
            },
            removePending: { _ in recorder.events.append("removePending") },
            removeDelivered: { _ in recorder.events.append("removeDelivered") }
        )
        var missingIdentity = Session.mock(
            id: "legacy-session", harnessSessionId: "legacy-session",
            status: .waitingInput, pid: 42_042, pidStartTime: 1_000,
            source: Session.opencodeSource
        )
        missingIdentity.cctopSessionId = nil
        missingIdentity.lifecycle = .active
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: FileManager.default.temporaryDirectory),
            dataSources: sources,
            startMonitoring: false
        )
        manager.sessions = [missingIdentity]

        manager.postNotification(for: missingIdentity)

        XCTAssertTrue(recorder.events.isEmpty)
    }

    @MainActor
    func testPostNotificationMatchesCurrentCanonicalObservationForPendingRequest() throws {
        final class Recorder {
            var requests: [UNNotificationRequest] = []
            var removals: [String] = []
        }

        let recorder = Recorder()
        var sources = try isolatedSessionDataSources(prefix: "cctop-canonical-notification").sources
        sources.notificationClient = SessionNotificationClient(
            add: { request, completion in
                recorder.requests.append(request)
                completion(nil)
            },
            removePending: { recorder.removals.append("pending:\($0.joined(separator: ","))") },
            removeDelivered: { recorder.removals.append("delivered:\($0.joined(separator: ","))") }
        )
        let sharedID = "11111111-1111-4111-8111-111111111111"
        var working = Session.mock(
            id: "first", cctopSessionId: sharedID,
            status: .working, pid: 11_111, source: Session.opencodeSource
        )
        working.lifecycle = .active
        var waiting = Session.mock(
            id: "second", cctopSessionId: sharedID,
            status: .waitingPermission, pid: 22_222, source: Session.opencodeSource
        )
        waiting.lifecycle = .active
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: FileManager.default.temporaryDirectory),
            dataSources: sources,
            startMonitoring: false
        )
        var staleWaitingSnapshot = working
        staleWaitingSnapshot.status = .waitingPermission
        staleWaitingSnapshot.notificationMessage = "Stale observation"
        waiting.notificationMessage = "Current observation"
        manager.sessions = [waiting]

        manager.postNotification(for: staleWaitingSnapshot)

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.content.body, "Current observation")
        XCTAssertEqual(request.identifier, "session-\(sharedID)")
        XCTAssertEqual(recorder.removals, [
            "pending:session-\(sharedID)",
            "delivered:session-\(sharedID)",
        ])

        recorder.requests.removeAll()
        recorder.removals.removeAll()
        manager.sessions = [working]
        manager.postNotification(for: staleWaitingSnapshot)
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertTrue(recorder.removals.isEmpty)
    }

    @MainActor
    func testHideSessionRemovesPermanentAndDurableLegacyNotifications() throws {
        final class Recorder {
            var pending: [[String]] = []
            var delivered: [[String]] = []
            var cctopSessionIDs: [String] = []
        }

        let recorder = Recorder()
        var sources = try isolatedSessionDataSources(prefix: "cctop-hide-all-notifications").sources
        sources.notificationsEnabled = { false }
        sources.notificationClient = SessionNotificationClient(
            add: { _, completion in completion(nil) },
            removePending: { recorder.pending.append($0) },
            removeDelivered: { recorder.delivered.append($0) },
            removeByCctopSessionID: { recorder.cctopSessionIDs.append($0) }
        )
        let sharedID = "11111111-1111-4111-8111-111111111111"
        let first = Session.mock(
            id: "codex-thread-1", cctopSessionId: sharedID,
            status: .working, pid: 11_111, source: Session.codexSource
        )
        let processScoped = Session.mock(
            id: "11111", cctopSessionId: sharedID,
            status: .working, pid: 11_111, source: Session.opencodeSource
        )
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: FileManager.default.temporaryDirectory),
            dataSources: sources,
            startMonitoring: false
        )
        manager.sessions = [first]

        manager.hideSession(first)

        let expectedIdentifiers = ["session-\(sharedID)", "session-codex:codex-thread-1"]
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertEqual(recorder.pending, [expectedIdentifiers])
        XCTAssertEqual(recorder.delivered, [expectedIdentifiers])
        XCTAssertNil(SessionIdentityPolicy.legacyNotificationRequestIdentifier(for: processScoped))
        XCTAssertEqual(recorder.cctopSessionIDs, [sharedID])
    }

    @MainActor
    func testHideSessionRemovesOutstandingAttentionNotification() throws {
        final class Recorder {
            var events: [String] = []
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cctop-hide-notification-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let historyDir = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "cctop-hide-notification-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = Recorder()
        var sources = SessionDataSources.live()
        sources.sessionsDir = sessionsDir
        sources.manualSessionVisibility = ManualSessionVisibilityStore(defaults: defaults)
        sources.notificationsEnabled = { false }
        sources.notificationClient = SessionNotificationClient(
            add: { _, completion in completion(nil) },
            removePending: { identifiers in
                recorder.events.append("pending:\(identifiers.joined(separator: ","))")
            },
            removeDelivered: { identifiers in
                recorder.events.append("delivered:\(identifiers.joined(separator: ","))")
            }
        )
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: historyDir),
            dataSources: sources,
            startMonitoring: false
        )
        let cctopSessionID = "11111111-1111-4111-8111-111111111111"
        var attention = Session.mock(
            id: "attention", cctopSessionId: cctopSessionID,
            status: .waitingInput, source: Session.codexSource
        )
        attention.lifecycle = .active
        manager.sessions = [attention]

        manager.hideSession(attention)

        XCTAssertEqual(manager.sessions, [])
        XCTAssertEqual(recorder.events, [
            "pending:session-\(cctopSessionID),session-codex:attention",
            "delivered:session-\(cctopSessionID),session-codex:attention",
        ])
    }

    func testNotificationActionsRemoveResolvedAttentionSession() {
        let cctopSessionID = "11111111-1111-4111-8111-111111111111"
        let oldSession = Session.mock(
            id: "old-observation", cctopSessionId: cctopSessionID,
            status: .waitingInput,
            lastPrompt: "Waiting",
            pid: 11_111, source: Session.opencodeSource
        )
        let resolvedSession = Session.mock(
            id: "new-observation", cctopSessionId: cctopSessionID,
            status: .working,
            pid: 22_222, source: Session.opencodeSource
        )

        XCTAssertEqual(
            SessionManager.notificationActions(
                newSessions: [resolvedSession],
                oldSessions: [oldSession],
                notificationsEnabled: true
            ),
            [.remove(cctopSessionID: cctopSessionID)]
        )
    }

    func testNotificationActionsRemoveMissingAttentionSession() {
        let cctopSessionID = "11111111-1111-4111-8111-111111111111"
        let oldSession = Session.mock(
            id: "codex-thread-1", cctopSessionId: cctopSessionID,
            status: .waitingInput,
            lastPrompt: "Waiting",
            source: "codex"
        )

        XCTAssertEqual(
            SessionManager.notificationActions(
                newSessions: [],
                oldSessions: [oldSession],
                notificationsEnabled: true
            ),
            [.remove(cctopSessionID: cctopSessionID)]
        )
    }

    @MainActor
    func testResolvedTransitionRemovesPermanentRequestAndPriorMetadataMatches() throws {
        final class Recorder {
            var pending: [[String]] = []
            var delivered: [[String]] = []
            var cctopSessionIDs: [String] = []
        }

        let recorder = Recorder()
        var sources = try isolatedSessionDataSources(prefix: "cctop-transition-notification-removal").sources
        sources.notificationClient = SessionNotificationClient(
            add: { _, completion in completion(nil) },
            removePending: { recorder.pending.append($0) },
            removeDelivered: { recorder.delivered.append($0) },
            removeByCctopSessionID: { recorder.cctopSessionIDs.append($0) }
        )
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: FileManager.default.temporaryDirectory),
            dataSources: sources,
            startMonitoring: false
        )
        let cctopSessionID = "11111111-1111-4111-8111-111111111111"
        let oldSession = Session.mock(
            id: "codex-thread-1", cctopSessionId: cctopSessionID,
            status: .waitingPermission, pid: 11_111, source: Session.codexSource
        )
        let currentSession = Session.mock(
            id: "codex-thread-1", cctopSessionId: cctopSessionID,
            status: .working, pid: 22_222, source: Session.codexSource
        )

        manager.syncTransitionNotifications(for: [currentSession], oldSessions: [oldSession])

        let identifiers = ["session-\(cctopSessionID)", "session-codex:codex-thread-1"]
        XCTAssertEqual(recorder.pending, [identifiers])
        XCTAssertEqual(recorder.delivered, [identifiers])
        XCTAssertEqual(recorder.cctopSessionIDs, [cctopSessionID])
    }

    func testNotificationActionsPostOneTransitionAcrossReplacementObservation() {
        let cctopSessionID = "11111111-1111-4111-8111-111111111111"
        let oldSession = Session.mock(
            id: "old-observation", cctopSessionId: cctopSessionID,
            status: .working, pid: 11_111, source: Session.opencodeSource
        )
        let waitingSession = Session.mock(
            id: "new-observation", cctopSessionId: cctopSessionID,
            status: .waitingInput,
            lastPrompt: "Waiting",
            pid: 22_222, source: Session.opencodeSource
        )

        XCTAssertEqual(
            SessionManager.notificationActions(
                newSessions: [waitingSession],
                oldSessions: [oldSession],
                notificationsEnabled: true
            ),
            [.post(session: waitingSession)]
        )
    }

    func testNotificationActionsDoNotRepostWaitingTransitionAcrossReplacementObservation() {
        let cctopSessionID = "11111111-1111-4111-8111-111111111111"
        let oldSession = Session.mock(
            id: "old-observation", cctopSessionId: cctopSessionID,
            status: .waitingPermission, pid: 11_111, source: Session.opencodeSource
        )
        let replacement = Session.mock(
            id: "new-observation", cctopSessionId: cctopSessionID,
            status: .waitingPermission, pid: 22_222, source: Session.opencodeSource
        )

        XCTAssertEqual(
            SessionManager.notificationActions(
                newSessions: [replacement], oldSessions: [oldSession], notificationsEnabled: true
            ),
            []
        )
    }

    func testNotificationActionsFailClosedWithoutPermanentIdentity() {
        var oldSession = Session.mock(id: "legacy", status: .working)
        var waitingSession = oldSession
        oldSession.cctopSessionId = nil
        waitingSession.cctopSessionId = nil
        waitingSession.status = .waitingInput
        waitingSession.lastPrompt = "Waiting"

        XCTAssertEqual(
            SessionManager.notificationActions(
                newSessions: [waitingSession], oldSessions: [oldSession], notificationsEnabled: true
            ),
            []
        )
    }

    private func notificationActions(
        newSession: Session,
        oldSession: Session,
        notificationsEnabled: Bool = true
    ) -> [SessionNotificationAction] {
        XCTAssertEqual(newSession.cctopSessionId, oldSession.cctopSessionId)
        return SessionManager.notificationActions(
            newSessions: [newSession],
            oldSessions: [oldSession],
            notificationsEnabled: notificationsEnabled
        )
    }

    func testNotificationActionsSuppressMachineOnlyCodexEnvelopeWaitingInput() {
        let oldSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .working,
            source: "codex"
        )
        let heartbeatSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .waitingInput,
            lastPrompt: """
            <heartbeat>
              <automation_id>cctop-chief-workflow-watchdog</automation_id>
            </heartbeat>
            """,
            source: "codex"
        )
        let delegationSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .waitingInput,
            lastPrompt: """
            <codex_delegation>
              <source_thread_id>019f3cfa</source_thread_id>
            </codex_delegation>
            """,
            source: "codex"
        )

        XCTAssertEqual(
            notificationActions(newSession: heartbeatSession, oldSession: oldSession),
            []
        )
        XCTAssertEqual(
            notificationActions(newSession: delegationSession, oldSession: oldSession),
            []
        )
    }

    func testNotificationActionsSuppressLegacyCodexDesktopMachineOnlyWaitingInput() {
        let oldSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .working,
            terminal: TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        )
        let heartbeatSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .waitingInput,
            lastPrompt: """
            <heartbeat>
              <automation_id>cctop-chief-workflow-watchdog</automation_id>
            </heartbeat>
            """,
            terminal: TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        )

        XCTAssertEqual(
            notificationActions(newSession: heartbeatSession, oldSession: oldSession),
            []
        )
    }

    func testNotificationActionsSuppressCodexScaffoldWithoutUserRequest() {
        let oldSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .working,
            source: "codex"
        )
        let browserScaffoldSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .waitingInput,
            lastPrompt: """
            # In app browser:
            - page: http://localhost:3000
            """,
            source: "codex"
        )
        let fileScaffoldSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .waitingInput,
            lastPrompt: """
            # Files:
            - /Users/test/project/App.swift
            """,
            source: "codex"
        )
        let multiSectionScaffoldSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .waitingInput,
            lastPrompt: """
            # Files:
            - /Users/test/project/App.swift

            # In app browser:
            - Current URL: http://localhost:3000
            """,
            source: "codex"
        )

        XCTAssertEqual(
            notificationActions(newSession: browserScaffoldSession, oldSession: oldSession),
            []
        )
        XCTAssertEqual(
            notificationActions(newSession: fileScaffoldSession, oldSession: oldSession),
            []
        )
        XCTAssertEqual(
            notificationActions(newSession: multiSectionScaffoldSession, oldSession: oldSession),
            []
        )
    }

    func testNotificationActionsDoNotApplyCodexSuppressionToLeakedDesktopBundle() {
        let oldSession = Session.mock(
            id: "cc-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .working,
            terminal: TerminalInfo(bundleId: HostAppBundleID.codexDesktop),
            source: "cc",
        )
        let waitingSession = Session.mock(
            id: "cc-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .waitingInput,
            lastPrompt: """
            # Files:
            - /Users/test/project/App.swift
            """,
            terminal: TerminalInfo(bundleId: HostAppBundleID.codexDesktop),
            source: "cc",
        )

        XCTAssertEqual(
            notificationActions(newSession: waitingSession, oldSession: oldSession),
            [.post(session: waitingSession)]
        )
    }

    func testNotificationActionsPostUserFacingCodexWaitingInput() {
        let oldSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .working,
            source: "codex"
        )
        let explicitMessageSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .waitingInput,
            lastPrompt: """
            <heartbeat>
              <automation_id>cctop-chief-workflow-watchdog</automation_id>
            </heartbeat>
            """,
            notificationMessage: "Which option should I choose?",
            source: "codex"
        )
        let scaffoldWithRequestSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .waitingInput,
            lastPrompt: """
            # In app browser:
            - page: http://localhost:3000

            ## My request for Codex:
            Click the export button and tell me what happens.
            """,
            source: "codex"
        )
        let promptStartingWithScaffoldHeading = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .waitingInput,
            lastPrompt: "# Files: draft a changelog entry",
            source: "codex"
        )
        let multilinePromptStartingWithScaffoldHeading = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .waitingInput,
            lastPrompt: """
            # Files:
            Draft a changelog entry for PR 213.
            """,
            source: "codex"
        )

        XCTAssertEqual(
            notificationActions(newSession: explicitMessageSession, oldSession: oldSession),
            [.post(session: explicitMessageSession)]
        )
        XCTAssertEqual(
            notificationActions(newSession: scaffoldWithRequestSession, oldSession: oldSession),
            [.post(session: scaffoldWithRequestSession)]
        )
        XCTAssertEqual(
            notificationActions(newSession: promptStartingWithScaffoldHeading, oldSession: oldSession),
            [.post(session: promptStartingWithScaffoldHeading)]
        )
        XCTAssertEqual(
            notificationActions(newSession: multilinePromptStartingWithScaffoldHeading, oldSession: oldSession),
            [.post(session: multilinePromptStartingWithScaffoldHeading)]
        )
    }

    func testNotificationActionsPostCodexPermissionAndErrorAttention() {
        let oldSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .working,
            source: "codex"
        )
        let permissionSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .waitingPermission,
            lastPrompt: "<heartbeat></heartbeat>",
            notificationMessage: "Allow Bash: make all",
            source: "codex"
        )
        let errorSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .needsAttention,
            lastPrompt: "<codex_delegation></codex_delegation>",
            notificationMessage: "Command failed",
            source: "codex"
        )

        XCTAssertEqual(
            notificationActions(newSession: permissionSession, oldSession: oldSession),
            [.post(session: permissionSession)]
        )
        XCTAssertEqual(
            notificationActions(newSession: errorSession, oldSession: oldSession),
            [.post(session: errorSession)]
        )
    }

    func testNotificationActionsPostWhenSuppressedCodexWaitingInputBecomesUserFacing() {
        let oldMachineOnlySession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .waitingInput,
            lastPrompt: "<heartbeat></heartbeat>",
            source: "codex"
        )
        let userFacingSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: notificationTestCctopSessionID,
            status: .waitingInput,
            lastPrompt: "yo",
            source: "codex"
        )

        XCTAssertEqual(
            notificationActions(newSession: userFacingSession, oldSession: oldMachineOnlySession),
            [.post(session: userFacingSession)]
        )
    }

    func testNotificationActionsRemoveWhenUserFacingCodexWaitingInputBecomesMachineOnly() {
        let cctopSessionID = "11111111-1111-4111-8111-111111111111"
        let oldUserFacingSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: cctopSessionID,
            status: .waitingInput,
            lastPrompt: "Can you check this?",
            source: "codex"
        )
        let machineOnlySession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: cctopSessionID,
            status: .waitingInput,
            lastPrompt: "<heartbeat></heartbeat>",
            source: "codex"
        )

        XCTAssertEqual(
            notificationActions(newSession: machineOnlySession, oldSession: oldUserFacingSession),
            [.remove(cctopSessionID: cctopSessionID)]
        )
    }

    func testNotificationActionsDoNotPostWhenNotificationsDisabled() {
        let cctopSessionID = "11111111-1111-4111-8111-111111111111"
        let oldSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: cctopSessionID,
            status: .working,
            source: "codex"
        )
        let waitingSession = Session.mock(
            id: "codex-thread-1",
            cctopSessionId: cctopSessionID,
            status: .waitingInput,
            lastPrompt: "Waiting",
            source: "codex"
        )

        XCTAssertEqual(
            SessionManager.notificationActions(
                newSessions: [waitingSession],
                oldSessions: [oldSession],
                notificationsEnabled: false
            ),
            []
        )
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
        XCTAssertEqual(object["cctop_session_id"] as? String, session.cctopSessionId)
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

    // MARK: - Liveness executable identity (issue #155)

    /// Spawn a real process whose kernel `p_comm` is `name` by copying /bin/sleep
    /// under that basename in a temp dir.
    private func spawnProcess(named name: String) throws -> Process {
        let dir = NSTemporaryDirectory() + "cctop-comm-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let bin = (dir as NSString).appendingPathComponent(name)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: bin)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["30"]
        try process.run()
        addTeardownBlock {
            process.terminate()
            process.waitUntilExit()
            try? FileManager.default.removeItem(atPath: dir)
        }
        return process
    }

    // A PID that now belongs to a DIFFERENT harness's binary cannot be this session's
    // host process, even when the start time matches (PID adoption/reuse, issue #155).
    func testIsAliveRejectsPidOwnedByForeignHarnessBinary() throws {
        let process = try spawnProcess(named: "codex")
        let pid = UInt32(process.processIdentifier)
        let start = try XCTUnwrap(Session.processStartTime(pid: pid))
        let session = Session.mock(pid: pid, pidStartTime: start, source: "cc")
        XCTAssertFalse(session.isAlive)
    }

    func testIsAliveAcceptsPidOwnedByOwnHarnessBinary() throws {
        let process = try spawnProcess(named: "codex")
        let pid = UInt32(process.processIdentifier)
        let start = try XCTUnwrap(Session.processStartTime(pid: pid))
        let session = Session.mock(pid: pid, pidStartTime: start, source: "codex")
        XCTAssertTrue(session.isAlive)
    }

    // Conservative by design: a comm that is not a known harness binary proves nothing.
    func testIsAliveAcceptsUnrecognizedProcessName() throws {
        let process = try spawnProcess(named: "sleepyhead")
        let pid = UInt32(process.processIdentifier)
        let start = try XCTUnwrap(Session.processStartTime(pid: pid))
        let session = Session.mock(pid: pid, pidStartTime: start, source: "cc")
        XCTAssertTrue(session.isAlive)
    }

    // Legacy files without a source are Claude Code sessions, so a codex-owned PID is foreign.
    func testIsAliveTreatsNilSourceAsClaudeCodeForIdentityCheck() throws {
        let process = try spawnProcess(named: "codex")
        let pid = UInt32(process.processIdentifier)
        let start = try XCTUnwrap(Session.processStartTime(pid: pid))
        let session = Session.mock(pid: pid, pidStartTime: start, source: nil)
        XCTAssertFalse(session.isAlive)
    }

    func testHarnessOwningCommRecognizesTruncatedArchSuffixedCodexBinary() {
        // Kernel p_comm of codex-aarch64-apple-darwin, truncated to MAXCOMLEN (16).
        XCTAssertEqual(Session.harnessOwningComm("codex-aarch64-ap"), Session.codexSource)
        XCTAssertTrue(Session.isForeignHarnessComm("codex-aarch64-ap", source: Session.ccSource))
        XCTAssertFalse(Session.isForeignHarnessComm("codex-aarch64-ap", source: Session.codexSource))
    }

    // Codex also ships arch-suffixed binaries; the kernel truncates p_comm to MAXCOMLEN.
    // The codex- prefix match must own the truncated name end to end.
    func testIsAliveRejectsPidOwnedByTruncatedArchSuffixedCodexBinary() throws {
        let process = try spawnProcess(named: "codex-aarch64-apple-darwin")
        let pid = UInt32(process.processIdentifier)
        XCTAssertEqual(Session.processCommandName(pid: pid), "codex-aarch64-ap")
        let start = try XCTUnwrap(Session.processStartTime(pid: pid))
        XCTAssertFalse(Session.mock(pid: pid, pidStartTime: start, source: "cc").isAlive)
        XCTAssertTrue(Session.mock(pid: pid, pidStartTime: start, source: "codex").isAlive)
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

    // A `cc` session is never hosted by Codex Desktop: that bundle id can only be
    // launcher environment leaked into a Claude Code child process (issue #155).
    func testHostClassCcIgnoresLeakedCodexDesktopBundle() {
        let session = Session.mock(
            terminal: TerminalInfo(bundleId: "com.openai.codex"),
            source: "cc"
        )
        XCTAssertEqual(session.hostClass, .ambiguous)
        XCTAssertFalse(session.isHostedByDesktopApp)
        XCTAssertFalse(session.isCodexDesktopHost)
    }

    // Symmetric: a `codex` session is never hosted by Claude Desktop.
    func testHostClassCodexIgnoresLeakedClaudeDesktopBundle() {
        let session = Session.mock(
            terminal: TerminalInfo(bundleId: "com.anthropic.claudefordesktop"),
            source: "codex"
        )
        XCTAssertEqual(session.hostClass, .ambiguous)
        XCTAssertFalse(session.isHostedByDesktopApp)
        XCTAssertFalse(session.isClaudeDesktopHost)
    }

    // The matching desktop apps stay trusted: cc -> Claude Desktop, codex -> Codex Desktop.
    func testHostClassCcWithClaudeDesktopBundleIsDesktop() {
        let session = Session.mock(
            terminal: TerminalInfo(bundleId: "com.anthropic.claudefordesktop"),
            source: "cc"
        )
        XCTAssertEqual(session.hostClass, .desktop)
        XCTAssertTrue(session.isClaudeDesktopHost)
    }

    func testHostClassCodexWithCodexDesktopBundleIsDesktop() {
        let session = Session.mock(
            terminal: TerminalInfo(bundleId: "com.openai.codex"),
            source: "codex"
        )
        XCTAssertEqual(session.hostClass, .desktop)
        XCTAssertTrue(session.isCodexDesktopHost)
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

    func testHostClassCmuxWithoutBundleIdIsTerminal() {
        let term = TerminalInfo(
            multiplexer: .cmux(
                socket: "/tmp/cmux.sock",
                workspaceId: "workspace:1",
                surfaceId: "surface:2",
                paneId: nil,
                binaryPath: nil
            )
        )
        XCTAssertEqual(Session.mock(terminal: term).hostClass, .terminal)
    }

    func testHostClassCmuxBundleIdIsTerminal() {
        let term = TerminalInfo(bundleId: "com.cmuxterm.app")
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

    // MARK: - Schema tripwire

    /// A `Session` with every optional field populated, both Bools true, and distinct values
    /// per field. Dates carry whole milliseconds so the sessionEncoder's fractional-second
    /// ISO 8601 format round-trips them exactly. `lifecycle` is deliberately left at `.active`
    /// because it is transient and never persisted.
    private func makeFullyPopulatedSession() -> Session {
        Session(
            sessionId: "full-fixture-1",
            harnessSessionId: "full-fixture-1|raw",
            projectPath: "/Users/test/projects/full-fixture",
            projectName: "full-fixture",
            branch: "feature/full-coverage",
            status: .working,
            lastPrompt: "Wire every field through",
            lastActivity: isoDate("2026-02-08T12:00:00.123Z"),
            startedAt: isoDate("2026-02-08T11:00:00.456Z"),
            terminal: TerminalInfo(
                program: "iTerm.app",
                sessionId: "w0t0p0:1A2B3C4D",
                tty: "/dev/ttys003",
                bundleId: "com.googlecode.iterm2",
                socket: "/tmp/kitty-socket",
                multiplexer: .tmux(socket: "/tmp/tmux-501/default", paneId: "%1", binaryPath: "/opt/homebrew/bin/tmux"),
                binaryPaths: ["tmux": "/opt/homebrew/bin/tmux"]
            ),
            pid: 4242,
            pidStartTime: 1707400000.5,
            lastTool: "Bash",
            lastToolDetail: "npm test",
            notificationMessage: "Permission needed",
            sessionName: "full fixture session",
            desktopProjectName: "full-fixture-desktop",
            workspaceFile: "/Users/test/projects/full-fixture/full-fixture.code-workspace",
            source: "codex",
            endedAt: isoDate("2026-02-08T13:00:00.789Z"),
            disconnectedAt: isoDate("2026-02-08T12:30:00.012Z"),
            activeSubagents: [
                SubagentInfo(agentId: "agent-1", agentType: "explore", startedAt: isoDate("2026-02-08T12:10:00.345Z"))
            ],
            isSubagentSession: true,
            hidden: true,
            createdByHookVersion: "0.16.0",
            lastWrittenByHookVersion: "0.17.2"
        )
    }

    private func isoDate(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)!
    }

    private func encodeToDictionary(_ session: Session) throws -> [String: Any] {
        let data = try JSONEncoder.sessionEncoder.encode(session)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // 27 persisted fields + the transient `lifecycle`. If this fails, a stored property was
    // added or removed: wire it through CodingKeys, init(from:), the memberwise init, and
    // makeFullyPopulatedSession() above, then update this count.
    func testStoredPropertyCountTripwire() {
        XCTAssertEqual(Mirror(reflecting: makeFullyPopulatedSession()).children.count, 28)
    }

    // Catches asymmetry between CodingKeys, init(from:), and the synthesized encode: a field
    // that encodes but doesn't decode (or vice versa) breaks equality after a round-trip.
    func testFullyPopulatedSessionRoundTripsThroughSessionCoders() throws {
        let session = makeFullyPopulatedSession()
        let data = try JSONEncoder.sessionEncoder.encode(session)
        let decoded = try JSONDecoder.sessionDecoder.decode(Session.self, from: data)
        XCTAssertEqual(decoded, session)
    }

    // Session-id rotation must be lossless: the rotated copy's persisted JSON differs from the
    // original in session_id only, so a future field forgotten in withSessionId fails loudly
    // instead of silently resetting on every Claude Code resume.
    func testWithSessionIdPreservesEveryPersistedField() throws {
        let session = makeFullyPopulatedSession()
        let rotated = session.withSessionId("rotated-id")

        var original = try encodeToDictionary(session)
        var copy = try encodeToDictionary(rotated)
        XCTAssertEqual(original["session_id"] as? String, "full-fixture-1")
        XCTAssertEqual(copy["session_id"] as? String, "rotated-id")
        original.removeValue(forKey: "session_id")
        copy.removeValue(forKey: "session_id")
        XCTAssertEqual(original as NSDictionary, copy as NSDictionary)
    }

    func testWithSessionIdAppliesBranchAndTerminalOverrides() {
        let session = makeFullyPopulatedSession()
        let newTerminal = TerminalInfo(program: "WezTerm", bundleId: "com.github.wez.wezterm")

        let rotated = session.withSessionId("rotated-id", branch: "hotfix/rotation", terminal: newTerminal)

        XCTAssertEqual(rotated.sessionId, "rotated-id")
        XCTAssertEqual(rotated.branch, "hotfix/rotation")
        XCTAssertEqual(rotated.terminal, newTerminal)
    }

    func testPermanentIDFocusResolverReturnsCurrentObservation() throws {
        let targetID = "11111111-2222-4333-8444-555555555555"
        let target = Session.mock(id: "abc", cctopSessionId: targetID, harnessSessionId: "abc", pid: 111)
        let other = Session.mock(id: "def", harnessSessionId: "def", pid: 222)

        let resolved = try XCTUnwrap(
            FocusTargetResolver.currentSession(
                forCctopSessionID: targetID,
                in: [other, target]
            )
        )
        XCTAssertEqual(resolved.sessionId, "abc")
    }

    func testPermanentIDFocusResolverRejectsInvalidIdentity() {
        let currentID = "11111111-2222-4333-8444-555555555555"
        let current = Session.mock(id: "current", cctopSessionId: currentID)

        XCTAssertNil(FocusTargetResolver.currentSession(forCctopSessionID: "111", in: [current]))
    }

    func testPermanentIDFocusResolverReturnsNilForMissingObservation() {
        let currentID = "11111111-2222-4333-8444-555555555555"
        let missingID = "22222222-3333-4444-8555-666666666666"
        let current = Session.mock(id: "current", cctopSessionId: currentID)

        XCTAssertNil(FocusTargetResolver.currentSession(forCctopSessionID: missingID, in: [current]))
        XCTAssertNil(FocusTargetResolver.currentSession(forCctopSessionID: currentID, in: []))
    }

    func testLogicalFocusResolverUsesFirstCanonicalPermanentObservation() {
        let cctopSessionID = "11111111-2222-4333-8444-555555555555"
        let first = Session.mock(id: "first", cctopSessionId: cctopSessionID, pid: 111)
        let second = Session.mock(id: "second", cctopSessionId: cctopSessionID, pid: 222)
        let identity = SessionIdentityPolicy.logicalIdentity(for: first)

        XCTAssertEqual(FocusTargetResolver.currentSession(for: identity, in: [first, second])?.pid, 111)
        XCTAssertEqual(FocusTargetResolver.currentSession(for: identity, in: [second, first])?.pid, 222)
    }

    func testLogicalFocusResolverKeepsLegacyFallbackUniqueAndFailsClosedWhenAmbiguous() {
        var first = Session.mock(id: "first", pid: 111, source: Session.opencodeSource)
        first.cctopSessionId = nil
        var duplicate = Session.mock(id: "duplicate", pid: 111, source: Session.opencodeSource)
        duplicate.cctopSessionId = nil
        let identity = SessionIdentityPolicy.logicalIdentity(for: first)

        XCTAssertEqual(FocusTargetResolver.currentSession(for: identity, in: [first])?.sessionId, "first")
        XCTAssertNil(FocusTargetResolver.currentSession(for: identity, in: [first, duplicate]))
        XCTAssertNil(FocusTargetResolver.currentSession(for: identity, in: []))
    }

    func testRepeatedCctopSessionIDKeepsRowsAndResolvesFirstCanonicalObservation() {
        let now = Date()
        let cctopSessionID = "11111111-2222-4333-8444-555555555555"
        var working = Session.mock(
            id: "conv-1", cctopSessionId: cctopSessionID, harnessSessionId: "conv-1", status: .working,
            pid: 111, pidStartTime: 1_000
        )
        working.lastActivity = now.addingTimeInterval(-10)
        var idle = Session.mock(
            id: "conv-1", cctopSessionId: cctopSessionID, harnessSessionId: "conv-1", status: .idle,
            pid: 999, pidStartTime: 2_000
        )
        idle.lastActivity = now.addingTimeInterval(-5)

        let snapshot = DisplayStateWriter.snapshot(
            sessions: [idle, working],
            theme: .claude,
            appRunning: true,
            appIdentity: nil,
            now: now
        )
        XCTAssertEqual(snapshot.sessions.count, 2)

        let ordered = SessionDisplayPolicy.activeSessions(from: [idle, working], now: now)
        XCTAssertEqual(ordered.count, 2)
        XCTAssertEqual(snapshot.sessions.map(\.cctopSessionId), [cctopSessionID, cctopSessionID])
        XCTAssertEqual(
            FocusTargetResolver.currentSession(forCctopSessionID: cctopSessionID, in: ordered)?.pid,
            ordered.first?.pid
        )
        XCTAssertEqual(
            FocusTargetResolver.currentSession(forCctopSessionID: cctopSessionID, in: Array(ordered.reversed()))?.pid,
            ordered.last?.pid
        )
    }

    // MARK: - Cctop session identity

    func testNewSessionsReceiveIndependentLowercaseUUIDs() throws {
        let terminal = TerminalInfo(program: "Terminal")
        let first = Session(sessionId: "same", projectPath: "/tmp/project", branch: "main", terminal: terminal)
        let second = Session(sessionId: "same", projectPath: "/tmp/project", branch: "main", terminal: terminal)
        let firstID = try XCTUnwrap(first.cctopSessionId)
        let secondID = try XCTUnwrap(second.cctopSessionId)

        XCTAssertTrue(Session.isValidCctopSessionId(firstID))
        XCTAssertTrue(Session.isValidCctopSessionId(secondID))
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(firstID, firstID.lowercased())
        XCTAssertEqual(secondID, secondID.lowercased())
    }

    func testCctopSessionIDDoesNotChangeWithFocusTargetMetadata() {
        let cctopSessionID = "11111111-2222-4333-8444-555555555555"
        let original = Session.mock(cctopSessionId: cctopSessionID, pid: 111, pidStartTime: 1_000)
        let resumed = Session.mock(cctopSessionId: cctopSessionID, pid: 999, pidStartTime: 2_000)

        XCTAssertEqual(original.cctopSessionId, resumed.cctopSessionId)
    }
}

final class CctopSessionIdentityStoreTests: XCTestCase {
    private var rootURL: URL!
    private var sessionsURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cctop-identity-store-\(UUID().uuidString)", isDirectory: true)
        sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func testDurableSourcesReuseOpaqueIdentityWithoutCrossSourceInference() throws {
        let reference = "11111111-2222-4333-8444-555555555555"
        let store = CctopSessionIdentityStore(sessionsDir: sessionsURL)

        let codexFirst = try store.resolve(
            source: Session.codexSource, harnessSessionId: reference, legacySessionId: reference
        )
        let codexAgain = try store.resolve(
            source: Session.codexSource, harnessSessionId: reference, legacySessionId: reference
        )
        let claude = try store.resolve(
            source: Session.ccSource, harnessSessionId: reference, legacySessionId: reference
        )

        XCTAssertEqual(codexFirst, codexAgain)
        XCTAssertNotEqual(codexFirst, claude)
        XCTAssertNotEqual(codexFirst, reference)
        XCTAssertTrue(Session.isValidCctopSessionId(codexFirst))
        XCTAssertTrue(Session.isValidCctopSessionId(claude))
    }

    func testUnsupportedAndSyntheticReferencesRemainRecordLocal() throws {
        let store = CctopSessionIdentityStore(sessionsDir: sessionsURL)
        let opencodeFirst = try store.resolve(
            source: Session.opencodeSource, harnessSessionId: "ses_abc", legacySessionId: "ses_abc"
        )
        let opencodeSecond = try store.resolve(
            source: Session.opencodeSource, harnessSessionId: "ses_abc", legacySessionId: "ses_abc"
        )
        let piFirst = try store.resolve(
            source: Session.piSource, harnessSessionId: "pi-123", legacySessionId: "pi-123"
        )
        let piSecond = try store.resolve(
            source: Session.piSource, harnessSessionId: "pi-123", legacySessionId: "pi-123"
        )

        XCTAssertNotEqual(opencodeFirst, opencodeSecond)
        XCTAssertNotEqual(piFirst, piSecond)
    }

    func testPiRealUUIDReusesCctopSessionID() throws {
        let reference = "11111111-2222-4333-8444-555555555555"
        let store = CctopSessionIdentityStore(sessionsDir: sessionsURL)

        let first = try store.resolve(
            source: Session.piSource, harnessSessionId: reference, legacySessionId: reference
        )
        let resumed = try store.resolve(
            source: Session.piSource, harnessSessionId: reference, legacySessionId: reference
        )

        XCTAssertEqual(first, resumed)
    }

    func testLegacyMissingSourceUsesClaudeResumeEvidence() throws {
        let reference = "11111111-2222-4333-8444-555555555555"
        let store = CctopSessionIdentityStore(sessionsDir: sessionsURL)

        let legacy = try store.resolve(
            source: nil, harnessSessionId: nil, legacySessionId: reference
        )
        let stamped = try store.resolve(
            source: Session.ccSource, harnessSessionId: reference, legacySessionId: reference
        )

        XCTAssertEqual(legacy, stamped)
    }

    func testConcurrentResolutionCreatesOnePrivateMapping() throws {
        let reference = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let queue = DispatchQueue(label: "cctop.identity-store.tests", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var ids: [String] = []
        var errors: [Error] = []

        for _ in 0..<12 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let id = try CctopSessionIdentityStore(sessionsDir: self.sessionsURL).resolve(
                        source: Session.codexSource,
                        harnessSessionId: reference,
                        legacySessionId: reference
                    )
                    lock.lock()
                    ids.append(id)
                    lock.unlock()
                } catch {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(Set(ids).count, 1)

        let identityDirectory = rootURL.appendingPathComponent("session-identities", isDirectory: true)
        let mapping = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: identityDirectory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: identityDirectory.path)[.posixPermissions] as? NSNumber
        )
        let mappingMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: mapping.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        XCTAssertEqual(mappingMode.intValue & 0o777, 0o600)
    }

    func testCorruptMappingFailsClosedWithoutReminting() throws {
        let reference = "11111111-2222-4333-8444-555555555555"
        let store = CctopSessionIdentityStore(sessionsDir: sessionsURL)
        _ = try store.resolve(
            source: Session.codexSource, harnessSessionId: reference, legacySessionId: reference
        )
        let identityDirectory = rootURL.appendingPathComponent("session-identities", isDirectory: true)
        let mapping = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: identityDirectory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )
        try Data("{}".utf8).write(to: mapping)

        XCTAssertThrowsError(
            try store.resolve(
                source: Session.codexSource, harnessSessionId: reference, legacySessionId: reference
            )
        )
    }
}
