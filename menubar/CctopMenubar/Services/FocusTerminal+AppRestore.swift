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
