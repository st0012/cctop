import Foundation

extension SessionData {
    static func mock(
        id: String = "test-123",
        cctopSessionId: String? = nil,
        harnessSessionId: String? = nil,
        project: String = "cctop",
        branch: String = "main",
        sessionName: String? = nil,
        status: SessionStatus = .idle,
        lastPrompt: String? = nil,
        pid: UInt32? = nil,
        pidStartTime: TimeInterval? = nil,
        lastTool: String? = nil,
        lastToolDetail: String? = nil,
        notificationMessage: String? = nil,
        terminal: TerminalInfo? = TerminalInfo(program: "Code", sessionId: nil, tty: nil),
        source: String? = nil,
        activeSubagents: [SubagentInfo]? = nil,
        desktopProjectName: String? = nil
    ) -> SessionData {
        var session = SessionData(
            sessionId: id,
            cctopSessionId: cctopSessionId ?? CctopSessionID.make(),
            harnessSessionId: harnessSessionId,
            projectPath: "/Users/test/projects/\(project)",
            projectName: project,
            branch: branch,
            status: status,
            lastPrompt: lastPrompt,
            lastActivity: Date(),
            startedAt: Date(),
            terminal: terminal,
            pid: pid,
            pidStartTime: pidStartTime,
            lastTool: lastTool,
            lastToolDetail: lastToolDetail,
            notificationMessage: notificationMessage,
            source: source,
            activeSubagents: activeSubagents
        )
        session.sessionName = sessionName
        session.desktopProjectName = desktopProjectName
        return session
    }

    static let mockSessions: [SessionData] = {
        var s1 = mock(
            id: "1", project: "cctop", branch: "pid-keyed-sessions",
            sessionName: "migrate-off-session-id",
            status: .working, lastTool: "Edit",
            lastToolDetail: "/Users/test/projects/cctop/CLAUDE.md"
        )
        // s1 keeps lastActivity = Date() (shows "0s ago")

        var s2 = mock(id: "2", project: "blog", branch: "main", status: .idle)
        s2.lastActivity = Date().addingTimeInterval(-120) // shows "2m ago"

        var s3 = mock(
            id: "3", project: "cctop", branch: "pid-keyed-sessions",
            sessionName: "Dave", status: .idle
        )
        s3.lastActivity = Date().addingTimeInterval(-5) // shows "5s ago"

        var s4 = mock(
            id: "4", project: "cctop", branch: "pid-keyed-sessions",
            status: .idle
        )
        s4.lastActivity = Date().addingTimeInterval(-10) // shows "10s ago"

        return [s1, s2, s3, s4]
    }()

    // MARK: - QA Scenarios

    /// 5 sessions: adds a working session to the baseline 4.
    /// Badges should show: 0 attention, 2 working, 3 idle
    static let qaFiveSessions: [SessionData] = mockSessions + [
        .mock(id: "5", project: "billing", branch: "feature/invoices", status: .working, lastTool: "Bash", lastToolDetail: "cargo test"),
    ]

    /// 6 sessions: adds two more to baseline 4.
    /// Badges should show: 0 attention, 2 working, 4 idle
    static let qaSixSessions: [SessionData] = qaFiveSessions + [
        .mock(id: "6", project: "infra", branch: "main", status: .idle),
    ]

    /// Showcase sessions for README screenshots — diverse projects, mixed sources,
    /// covers the distinct agent badge variants (CC, Claude Desktop, Codex)
    /// and both attention pills (Permission + Waiting). Permission sorts above
    /// waitingInput, so the top card always shows the dedicated red-orange "Permission"
    /// pill alongside its italic notification note.
    static let qaShowcase: [SessionData] = {
        // Top of list — waitingPermission sorts above everything else.
        // Demos the dedicated "Permission" pill + italic permission note.
        var s1 = mock(
            id: "1", project: "cctop", branch: "redesign",
            sessionName: "Verify migration safety",
            status: .waitingPermission,
            notificationMessage: "Allow Bash: rm -rf node_modules",
            source: "cc"
        )
        s1.lastActivity = Date().addingTimeInterval(-10) // "10s ago"

        // waitingInput sits just under permission. A Codex session here pairs the
        // pulsing amber "Waiting" pill with the Codex badge.
        var s2 = mock(
            id: "2", project: "billing-api", branch: "main",
            sessionName: "Investigate staging deploy regression",
            status: .waitingInput,
            lastPrompt: "Should we retry on 5xx or surface to the user?",
            source: "codex"
        )
        s2.lastActivity = Date().addingTimeInterval(-180) // "3m ago"

        var s3 = mock(
            id: "3", project: "cctop", branch: "main",
            sessionName: "Review session card redesign",
            status: .working, lastTool: "Read",
            lastToolDetail: "/src/SessionCardView.swift",
            source: "cc"
        )
        // s3.lastActivity is Date() → "just now"

        var s4 = mock(
            id: "4", project: "infra-tools", branch: "main",
            sessionName: "Trace flaky integration test",
            status: .working, lastTool: "Bash",
            lastToolDetail: "./scripts/run-integration-tests.sh --filter staging",
            terminal: TerminalInfo(bundleId: "com.anthropic.claudefordesktop"),
            source: nil,
            desktopProjectName: "infra-tools"
        )
        s4.lastActivity = Date().addingTimeInterval(-30) // "30s ago"

        // lastTool: "local_shell" matches what Codex actually emits (its only
        // tool-tracked event). formatToolDisplay routes "local_shell" through
        // the same "Running: ..." rendering as "bash".
        var s5 = mock(
            id: "5", project: "deploy-pipeline", branch: "main",
            status: .working, lastTool: "local_shell",
            lastToolDetail: "./scripts/deploy.sh --plan staging",
            source: "codex"
        )
        s5.lastActivity = Date().addingTimeInterval(-300) // "5m ago"

        var s6 = mock(id: "6", project: "cctop", branch: "master", status: .idle, source: "cc")
        s6.lastActivity = Date().addingTimeInterval(-1_296_000) // "15d ago"

        return [s1, s2, s3, s4, s5, s6]
    }()
}
