import Foundation

func resolveRecentResumeTargetOpenStrategy(target: RecentResumeTarget) -> FocusStrategy {
    switch target {
    case .project(let project):
        return resolveRecentProjectOpenStrategy(project: project)
    case .desktopThread:
        // Archived Claude Desktop rows are manual find/unarchive aids.
        return .activateByBundleID(HostAppBundleID.claudeDesktop)
    }
}
