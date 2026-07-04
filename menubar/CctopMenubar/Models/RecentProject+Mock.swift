import Foundation

extension RecentProject {
    static func mock(
        project: String = "my-project",
        branch: String = "main",
        daysAgo: Int = 1,
        sessionCount: Int = 3,
        editor: String? = "Cursor",
        agent: String? = "Codex",
        workspaceFile: String? = nil
    ) -> RecentProject {
        RecentProject(
            projectPath: "/Users/dev/projects/\(project)",
            projectName: project,
            lastBranch: branch,
            lastSessionAt: Date().addingTimeInterval(TimeInterval(-daysAgo * 86400)),
            sessionCount: sessionCount,
            lastEditor: editor,
            lastAgent: agent,
            workspaceFile: workspaceFile
        )
    }

    static let mockRecents: [RecentProject] = [
        .mock(project: "billing-api", branch: "feature/invoices",
              daysAgo: 0, sessionCount: 12, editor: "Cursor", agent: "Codex"),
        .mock(project: "landing-page", branch: "redesign",
              daysAgo: 1, sessionCount: 5, editor: "Code", agent: "Claude Code"),
        .mock(project: "infra", branch: "main",
              daysAgo: 3, sessionCount: 8, editor: nil, agent: "opencode"),
        .mock(project: "mobile-app", branch: "release/2.0",
              daysAgo: 5, sessionCount: 2, editor: "Cursor", agent: "pi"),
        .mock(project: "data-pipeline", branch: "fix/backfill",
              daysAgo: 7, sessionCount: 1, editor: nil, agent: "Claude Code"),
    ]
}
