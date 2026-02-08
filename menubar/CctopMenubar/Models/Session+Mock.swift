import Foundation

extension Session {
    static func mock(
        id: String = "test-123",
        project: String = "cctop",
        branch: String = "main",
        status: SessionStatus = .idle,
        lastPrompt: String? = nil,
        lastTool: String? = nil,
        lastToolDetail: String? = nil,
        notificationMessage: String? = nil
    ) -> Session {
        Session(
            sessionId: id,
            projectPath: "/Users/test/projects/\(project)",
            projectName: project,
            branch: branch,
            status: status,
            lastPrompt: lastPrompt,
            lastActivity: Date(),
            startedAt: Date(),
            terminal: TerminalInfo(program: "Code", sessionId: nil, tty: nil),
            pid: nil,
            lastTool: lastTool,
            lastToolDetail: lastToolDetail,
            notificationMessage: notificationMessage,
            contextCompacted: false
        )
    }

    static let mockSessions: [Session] = [
        .mock(id: "1", project: "cctop", branch: "main", status: .waitingPermission, notificationMessage: "Allow Bash: npm test"),
        .mock(id: "2", project: "my-app", branch: "feature/auth", status: .working, lastTool: "Edit", lastToolDetail: "/src/auth.ts"),
        .mock(id: "3", project: "api-server", branch: "fix/timeout", status: .waitingInput, lastPrompt: "Should I also update the retry logic?"),
        .mock(id: "4", project: "docs", branch: "main", status: .idle),
    ]
}
