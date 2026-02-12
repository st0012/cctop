import Foundation

extension Session {
    static func mock(
        id: String = "test-123",
        project: String = "cctop",
        branch: String = "main",
        sessionName: String? = nil,
        status: SessionStatus = .idle,
        lastPrompt: String? = nil,
        pid: UInt32? = nil,
        pidStartTime: TimeInterval? = nil,
        lastTool: String? = nil,
        lastToolDetail: String? = nil,
        notificationMessage: String? = nil
    ) -> Session {
        var session = Session(
            sessionId: id,
            projectPath: "/Users/test/projects/\(project)",
            projectName: project,
            branch: branch,
            status: status,
            lastPrompt: lastPrompt,
            lastActivity: Date(),
            startedAt: Date(),
            terminal: TerminalInfo(program: "Code", sessionId: nil, tty: nil),
            pid: pid,
            pidStartTime: pidStartTime,
            lastTool: lastTool,
            lastToolDetail: lastToolDetail,
            notificationMessage: notificationMessage
        )
        session.sessionName = sessionName
        return session
    }

    static let mockSessions: [Session] = [
        .mock(id: "1", project: "cctop", branch: "main", status: .waitingPermission, notificationMessage: "Allow Bash: npm test"),
        .mock(id: "2", project: "my-app", branch: "feature/auth",
              sessionName: "refactor auth flow",
              status: .working, lastTool: "Edit", lastToolDetail: "/src/auth.ts"),
        .mock(id: "3", project: "api-server", branch: "fix/timeout", status: .waitingInput, lastPrompt: "Should I also update the retry logic?"),
        .mock(id: "4", project: "docs", branch: "main", status: .idle),
    ]

    // MARK: - QA Scenarios

    /// 5 sessions: adds a working session to the baseline 4.
    /// Badges should show: 2 attention, 2 working, 1 idle
    static let qaFiveSessions: [Session] = mockSessions + [
        .mock(id: "5", project: "billing", branch: "feature/invoices", status: .working, lastTool: "Bash", lastToolDetail: "cargo test"),
    ]

    /// 6 sessions: adds two more to baseline 4.
    /// Badges should show: 2 attention, 2 working, 2 idle
    static let qaSixSessions: [Session] = mockSessions + [
        .mock(id: "5", project: "billing", branch: "feature/invoices", status: .working, lastTool: "Bash", lastToolDetail: "cargo test"),
        .mock(id: "6", project: "infra", branch: "main", status: .idle),
    ]

    /// 8 sessions: tests scrolling behavior.
    static let qaEightSessions: [Session] = mockSessions + [
        .mock(id: "5", project: "billing", branch: "feature/invoices", status: .working, lastTool: "Bash", lastToolDetail: "cargo test"),
        .mock(id: "6", project: "infra", branch: "main", status: .idle),
        .mock(id: "7", project: "mobile-app", branch: "release/2.0",
              status: .waitingPermission, notificationMessage: "Allow Write: /config/prod.json"),
        .mock(id: "8", project: "analytics", branch: "fix/dashboard", status: .working, lastTool: "Grep", lastToolDetail: "*.ts"),
    ]

    /// All sessions needing attention (only amber badge visible).
    static let qaAllAttention: [Session] = [
        .mock(id: "1", project: "web-app", branch: "main", status: .waitingPermission, notificationMessage: "Allow Bash: rm -rf node_modules"),
        .mock(id: "2", project: "api", branch: "develop", status: .waitingInput, lastPrompt: "Which database migration strategy?"),
        .mock(id: "3", project: "worker", branch: "main", status: .needsAttention),
    ]

    /// All sessions idle (only gray badge visible).
    static let qaAllIdle: [Session] = [
        .mock(id: "1", project: "project-a", branch: "main", status: .idle),
        .mock(id: "2", project: "project-b", branch: "develop", status: .idle),
        .mock(id: "3", project: "project-c", branch: "main", status: .idle),
        .mock(id: "4", project: "project-d", branch: "feature/x", status: .idle),
    ]

    /// Long project and branch names to test truncation.
    static let qaLongNames: [Session] = [
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

    /// Single session.
    static let qaSingle: [Session] = [
        .mock(id: "1", project: "solo-project", branch: "main", status: .working, lastTool: "Task", lastToolDetail: "Running tests"),
    ]
}
