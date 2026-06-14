import AppKit
import Foundation

struct DesktopAppConnectionLookup {
    let runningStates: (Set<String>) -> [String: Bool]

    init(_ isRunning: @escaping (String) -> Bool) {
        self.runningStates = { bundleIDs in
            Dictionary(uniqueKeysWithValues: bundleIDs.map { ($0, isRunning($0)) })
        }
    }

    init(runningStates: @escaping (Set<String>) -> [String: Bool]) {
        self.runningStates = runningStates
    }

    func isRunning(_ bundleID: String) -> Bool {
        runningStates([bundleID])[bundleID] ?? false
    }

    static let live = DesktopAppConnectionLookup(runningStates: { bundleIDs in
        guard !bundleIDs.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: bundleIDs.map { bundleID in
            (bundleID, !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty)
        })
    })
}
