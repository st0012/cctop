import AppKit

@discardableResult
func restoreAndActivate(_ app: NSRunningApplication) -> Bool {
    if let bundleID = app.bundleIdentifier {
        restoreAppByBundleID(bundleID)
    }
    return app.activate(options: [.activateAllWindows])
}

/// Launch (or bring forward) an app by bundle ID. No-ops if the app isn't installed.
func restoreAppByBundleID(_ bundleID: String) {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
}

@discardableResult
func activateAppByBundleID(_ bundleID: String) -> Bool {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == bundleID
    }) else {
        // App not running — launch it (optimistic true; restoreAppByBundleID no-ops if the app isn't installed).
        restoreAppByBundleID(bundleID)
        return true
    }
    return restoreAndActivate(app)
}

@discardableResult
func activateAppByName(_ program: String) -> Bool {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName?.lowercased().contains(program) == true
    }) else {
        return false
    }
    return restoreAndActivate(app)
}

func restoreAppAndOpenURL(bundleID: String, url: URL) {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        NSWorkspace.shared.open(url)
        return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
        NSWorkspace.shared.open(url)
    }
}
