import Foundation

extension CodexThreadArchiveLookup {
    static func archiveState(sqliteArchived: Bool, rolloutPath: String?) -> CodexThreadArchiveState {
        guard let rolloutPath else {
            return CodexThreadArchiveState(isArchived: sqliteArchived, observedFingerprints: [:])
        }

        var observedFingerprints = [rolloutPath: rolloutFileFingerprint(at: rolloutPath)]
        let siblingPath = siblingRolloutPath(for: rolloutPath)
        let rolloutExists = observedFingerprints[rolloutPath]?.file != nil
        let siblingExists: Bool
        if let siblingPath {
            observedFingerprints[siblingPath] = rolloutFileFingerprint(at: siblingPath)
            siblingExists = observedFingerprints[siblingPath]?.file != nil
        } else {
            siblingExists = false
        }

        if rolloutExists != siblingExists {
            let existingPath = rolloutExists ? rolloutPath : siblingPath
            if let existingPath, isArchivedRolloutPath(existingPath) {
                return CodexThreadArchiveState(
                    isArchived: true,
                    observedFingerprints: observedFingerprints,
                    existingRolloutPath: existingPath
                )
            }
            if let existingPath, isActiveRolloutPath(existingPath) {
                return CodexThreadArchiveState(
                    isArchived: false,
                    observedFingerprints: observedFingerprints,
                    existingRolloutPath: existingPath
                )
            }
        }

        return CodexThreadArchiveState(isArchived: sqliteArchived, observedFingerprints: observedFingerprints)
    }

    private static func siblingRolloutPath(for path: String) -> String? {
        archivedSiblingPath(forActiveRolloutPath: path) ?? activeSiblingPath(forArchivedRolloutPath: path)
    }

    private static func archivedSiblingPath(forActiveRolloutPath path: String) -> String? {
        guard isActiveRolloutPath(path),
              let range = path.range(of: "/sessions/", options: .backwards) else {
            return nil
        }
        let codexHome = String(path[..<range.lowerBound])
        let filename = (path as NSString).lastPathComponent
        return (codexHome as NSString).appendingPathComponent("archived_sessions/\(filename)")
    }

    private static func activeSiblingPath(forArchivedRolloutPath path: String) -> String? {
        guard isArchivedRolloutPath(path),
              let range = path.range(of: "/archived_sessions/", options: .backwards),
              let date = rolloutDateComponents(from: (path as NSString).lastPathComponent) else {
            return nil
        }
        let codexHome = String(path[..<range.lowerBound])
        let filename = (path as NSString).lastPathComponent
        return (codexHome as NSString)
            .appendingPathComponent("sessions/\(date.year)/\(date.month)/\(date.day)/\(filename)")
    }

    private static func isArchivedRolloutPath(_ path: String) -> Bool {
        path.contains("/archived_sessions/")
    }

    private static func isActiveRolloutPath(_ path: String) -> Bool {
        path.contains("/sessions/") && !isArchivedRolloutPath(path)
    }

    private static func rolloutDateComponents(from filename: String) -> (year: Substring, month: Substring, day: Substring)? {
        let prefix = "rollout-"
        guard filename.hasPrefix(prefix) else { return nil }
        let dateStart = filename.index(filename.startIndex, offsetBy: prefix.count)
        guard let dateEnd = filename[dateStart...].firstIndex(of: "T") else { return nil }
        let parts = filename[dateStart..<dateEnd].split(separator: "-")
        guard parts.count == 3 else { return nil }
        return (year: parts[0], month: parts[1], day: parts[2])
    }
}

struct CodexThreadArchiveState {
    let isArchived: Bool
    let observedFingerprints: [String: CodexThreadStateRolloutFileFingerprint]
    let existingRolloutPath: String?

    init(
        isArchived: Bool,
        observedFingerprints: [String: CodexThreadStateRolloutFileFingerprint],
        existingRolloutPath: String? = nil
    ) {
        self.isArchived = isArchived
        self.observedFingerprints = observedFingerprints
        self.existingRolloutPath = existingRolloutPath
    }
}
