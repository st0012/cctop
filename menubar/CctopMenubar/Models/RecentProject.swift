import Foundation

/// Represents a recently accessed project with metadata like path, name, last session, and editor information.
/// - Important: Used for tracking project history in the menubar.
struct RecentProject: Identifiable {
    let projectPath: String
    let projectName: String
    let lastBranch: String
    let lastSessionAt: Date
    let sessionCount: Int
    let lastEditor: String?
    let workspaceFile: String?

    var id: String { projectPath }

    var relativeTime: String {
        lastSessionAt.relativeDescription
    }

    var editorIcon: String {
        HostApp.from(editorName: lastEditor).sfSymbol
    }
}
