import Foundation

func resolveRecentProjectOpenStrategy(project: RecentProject) -> FocusStrategy {
    // Prefer the captured bundle ID over the display name when it identifies a
    // known project opener on its own: one name can cover several bundle IDs
    // (Warp release channels all display as "Warp"), and only the captured ID
    // reopens the exact app that hosted the session. An unrecognized stored ID
    // (tampered history, uninstalled fork) falls back to the name-derived app.
    let storedOpener = HostApp.projectOpener(fromStoredBundleIdentifier: project.lastEditorBundleId)
    guard let hostApp = storedOpener ?? HostApp.projectOpener(fromProgramName: project.lastEditor),
          let bundleID = storedOpener != nil ? project.lastEditorBundleId : hostApp.bundleID else {
        return .openInFinder(project.projectPath)
    }

    let target: String
    if hostApp.usesWorkspaceFile {
        target = project.workspaceFile
            ?? Session.findWorkspaceFile(in: project.projectPath)
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

func openInEditor(project: RecentProject) {
    executeFocusStrategy(resolveRecentProjectOpenStrategy(project: project))
}

func openRecentResumeTarget(_ target: RecentResumeTarget) {
    executeFocusStrategy(resolveRecentResumeTargetOpenStrategy(target: target))
}
