import AppKit

enum FocusFailure: Equatable {
    case codexAppNotInstalled
    case codexTaskIdentifierInvalid
    case codexTaskOpenFailed

    var message: String {
        switch self {
        case .codexAppNotInstalled:
            return "cctop could not find the Codex app. Install Codex, then try again."
        case .codexTaskIdentifierInvalid:
            return "cctop could not open this task because its Codex identifier is invalid. "
                + "Open Codex and select the task manually."
        case .codexTaskOpenFailed:
            return "cctop could not open this task in Codex. Open Codex, then try again."
        }
    }
}

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

func restoreAppAndOpenURL(bundleID: String, url: URL, completion: @escaping (FocusFailure?) -> Void) {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        completion(.codexAppNotInstalled)
        return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
        DispatchQueue.main.async {
            completion(error == nil ? nil : .codexTaskOpenFailed)
        }
    }
}

func executeAppURLStrategy(url: URL, restoreBundleID: String?) -> Bool {
    DispatchQueue.main.async {
        if let restoreBundleID {
            restoreAppAndOpenURL(bundleID: restoreBundleID, url: url) { failure in
                if let failure {
                    presentFocusFailure(failure)
                } else {
                    NSApp.deactivate()
                }
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
    return restoreBundleID == nil
}

func presentFocusFailure(_ failure: FocusFailure) {
    NSRunningApplication.current.activate(options: [.activateAllWindows])
    let alert = NSAlert()
    alert.messageText = "Could Not Open Codex Task"
    alert.informativeText = failure.message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
