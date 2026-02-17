import Foundation

extension RecentProject {
    static func mock(
        project: String = "my-project",
        branch: String = "main",
        daysAgo: Int = 1,
        sessionCount: Int = 3,
        editor: String? = "Cursor",
        workspaceFile: String? = nil
    ) -> RecentProject {
        RecentProject(
            projectPath: "/Users/dev/projects/\(project)",
            projectName: project,
            lastBranch: branch,
            lastSessionAt: Date().addingTimeInterval(TimeInterval(-daysAgo * 86400)),
            sessionCount: sessionCount,
            lastEditor: editor,
            workspaceFile: workspaceFile
        )
    }

    static let mockRecents: [RecentProject] = [
        .mock(project: "billing-api", branch: "feature/invoices",
              daysAgo: 0, sessionCount: 12, editor: "Cursor"),
        .mock(project: "landing-page", branch: "redesign",
              daysAgo: 1, sessionCount: 5, editor: "Code"),
        .mock(project: "infra", branch: "main",
              daysAgo: 3, sessionCount: 8, editor: "iTerm2"),
        .mock(project: "mobile-app", branch: "release/2.0",
              daysAgo: 5, sessionCount: 2, editor: "Cursor"),
        .mock(project: "data-pipeline", branch: "fix/backfill",
              daysAgo: 7, sessionCount: 1, editor: nil),
    ]
}
