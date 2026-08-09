import Foundation

func resolveRecentProjectOpenStrategy(project: RecentProject) -> FocusStrategy {
    guard let opener = project.lastEditor,
          let hostApp = HostApp.projectOpener(fromProgramName: opener),
          let bundleID = hostApp.bundleID else {
        return .openInFinder(project.projectPath)
    }

    let target: String
    if hostApp.usesWorkspaceFile {
        target = project.workspaceFile
            ?? SessionData.findWorkspaceFile(in: project.projectPath)
            ?? project.projectPath
    } else {
        target = project.projectPath
    }
    return .openWithApp(bundleID: bundleID, target: target)
}

func resolveRecentResumeTargetOpenStrategy(target: RecentResumeTarget) -> FocusStrategy {
    switch target {
    case .project(let project):
        return resolveRecentProjectOpenStrategy(project: project)
    case .desktopThread:
        // Archived Claude Desktop rows are manual find/unarchive aids.
        return .activateByBundleID(HostAppBundleID.claudeDesktop)
    }
}
