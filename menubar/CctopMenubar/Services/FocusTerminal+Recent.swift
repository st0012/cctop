import Foundation

func resolveRecentResumeTargetOpenStrategy(target: RecentResumeTarget) -> FocusStrategy {
    switch target {
    case .project(let project):
        return resolveRecentProjectOpenStrategy(project: project)
    case .desktopThread(let thread):
        guard let bundleID = thread.sourceApp.bundleID else {
            return .openInFinder(thread.projectPath)
        }
        // Archived desktop rows are manual find/unarchive aids. Codex thread URLs
        // can foreground the app without landing on the archived thread.
        return .activateByBundleID(bundleID)
    }
}
