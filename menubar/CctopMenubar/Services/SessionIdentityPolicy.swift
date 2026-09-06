import Foundation

enum SessionIdentityPolicy {
    enum LogicalIdentity: Hashable {
        case permanent(UUID)
        case legacy(String)

        var cctopSessionID: String? {
            guard case .permanent(let id) = self else { return nil }
            return id.uuidString.lowercased()
        }
    }

    static let notificationSessionIDKey = "sessionID"
    static let notificationCctopSessionIDKey = "cctopSessionID"

    /// Legacy grouping key used by pre-ID dedup and conservative compatibility paths.
    static func stableKey(for session: SessionData) -> String {
        if session.isCodex {
            return "codex:\(session.sessionId)"
        }
        if session.hostClass == .desktop {
            return "desktop:\(session.sessionId)"
        }
        return "active:\(session.id)"
    }

    /// Panel identity prefers cctop's permanent UUID. Legacy records retain the existing
    /// source- and host-aware key until a permanent ID becomes available.
    static func logicalIdentity(for session: SessionData) -> LogicalIdentity {
        if let cctopSessionID = session.cctopSessionId,
           CctopSessionID.isValid(cctopSessionID),
           let id = UUID(uuidString: cctopSessionID) {
            return .permanent(id)
        }
        return .legacy(stableKey(for: session))
    }

    static func notificationRequestIdentifier(forCctopSessionID cctopSessionID: String) -> String? {
        guard CctopSessionID.isValid(cctopSessionID) else { return nil }
        return "session-\(cctopSessionID)"
    }

    static func notificationUserInfo(forCctopSessionID cctopSessionID: String) -> [AnyHashable: Any]? {
        guard CctopSessionID.isValid(cctopSessionID) else { return nil }
        return [notificationCctopSessionIDKey: cctopSessionID]
    }

    /// Identifier used by already-delivered pre-migration notifications with durable
    /// Codex or desktop conversation identity. Process-scoped records are excluded.
    static func legacyNotificationRequestIdentifier(for session: SessionData) -> String? {
        guard session.isCodex || session.hostClass == .desktop,
              !notificationSessionID(for: session).isEmpty else { return nil }
        return "session-\(stableKey(for: session))"
    }

    static func cctopSessionID(matchingNotificationUserInfo userInfo: [AnyHashable: Any]) -> String? {
        guard let cctopSessionID = nonEmptyString(userInfo[notificationCctopSessionIDKey]),
              CctopSessionID.isValid(cctopSessionID) else { return nil }
        return cctopSessionID
    }

    /// Recover a user session from a pre-migration notification even when the named
    /// session record has not been stamped yet. The user-session group remains authoritative.
    static func notificationCctopSessionID(
        matchingNotificationUserInfo userInfo: [AnyHashable: Any],
        in userSessions: [UserSession]
    ) -> String? {
        if let permanentValue = userInfo[notificationCctopSessionIDKey] {
            guard let cctopSessionID = nonEmptyString(permanentValue),
                  CctopSessionID.isValid(cctopSessionID) else { return nil }
            return cctopSessionID
        }

        guard let sessionIDValue = userInfo[notificationSessionIDKey],
              let sessionID = nonEmptyString(sessionIDValue) else { return nil }
        let matches = userSessions.filter { userSession in
            userSession.records.contains { record in
                let data = record.data
                return (data.isCodex || data.hostClass == .desktop)
                    && notificationSessionID(for: data) == sessionID
            }
        }
        guard !matches.isEmpty else { return nil }
        var permanentIDs: Set<String> = []
        for match in matches {
            guard let cctopSessionID = match.identity.cctopSessionID else { return nil }
            permanentIDs.insert(cctopSessionID)
        }
        guard permanentIDs.count == 1 else { return nil }
        return permanentIDs.first
    }

    private static func notificationSessionID(for session: SessionData) -> String {
        if session.isCodex || session.hostClass == .desktop {
            return session.sessionId
        }
        return session.id
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// Collapse multiple files for one conversation only for hosts with stable conversation identity.
    static func dedupedCandidatesByStableKey(_ candidates: [SessionRecord]) -> [SessionRecord] {
        var byKey: [String: SessionRecord] = [:]
        for candidate in candidates {
            let key = stableKey(for: candidate.data)
            if let existing = byKey[key], SessionLifecyclePolicy.prefers(existing, over: candidate) { continue }
            byKey[key] = candidate
        }
        return byKey.values.sorted { stableKey(for: $0.data) < stableKey(for: $1.data) }
    }

}

/// One pass's snapshot of the manual hides that apply to a session inventory. Built once
/// per load/GC pass so the visibility filter, cleanup retention, and file sweeps agree.
struct ManualHideEvidence {
    let hiddenSessionIDs: Set<String>

    func matches(_ session: SessionData) -> Bool {
        guard let cctopSessionID = session.cctopSessionId else { return false }
        return hiddenSessionIDs.contains(cctopSessionID)
    }
}

/// Persists manual visibility preferences independently from hook-owned session files.
/// The stored payload is intentionally limited to opaque cctop-owned session IDs.
struct ManualSessionVisibilityStore {
    static let defaultsKey = "manuallyHiddenCctopSessionIDs"
    static let live = ManualSessionVisibilityStore(defaults: .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var hiddenSessionIDs: Set<String> {
        Set((defaults.stringArray(forKey: Self.defaultsKey) ?? []).filter(CctopSessionID.isValid))
    }

    var hasStoredHideEvidence: Bool {
        !hiddenSessionIDs.isEmpty
    }

    /// Snapshot the manual-hide state for one load or GC pass.
    var manualHideEvidence: ManualHideEvidence {
        ManualHideEvidence(hiddenSessionIDs: hiddenSessionIDs)
    }

    func isHidden(cctopSessionID: String) -> Bool {
        guard CctopSessionID.isValid(cctopSessionID) else { return false }
        return hiddenSessionIDs.contains(cctopSessionID)
    }

    func hide(cctopSessionID: String) {
        guard CctopSessionID.isValid(cctopSessionID) else { return }
        var sessionIDs = hiddenSessionIDs
        sessionIDs.insert(cctopSessionID)
        save(sessionIDs)
    }

    /// Remove IDs only after the caller has completed an authoritative local inventory.
    func prune(retaining validSessionIDs: Set<String>) {
        let current = hiddenSessionIDs
        let retained = current.intersection(validSessionIDs)
        guard retained != current else { return }
        save(retained)
    }

    private func save(_ sessionIDs: Set<String>) {
        if sessionIDs.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(sessionIDs.sorted(), forKey: Self.defaultsKey)
        }
    }

}
