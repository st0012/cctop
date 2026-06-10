import Foundation

enum SessionIdentityPolicy {
    static let notificationSessionIDKey = "sessionID"
    static let notificationSessionPIDKey = "sessionPID"

    /// UI identity. Codex multiplexes many conversations onto one host process, so its PID is
    /// not unique per conversation; every other source keeps the existing PID identity.
    static func displayID(for session: Session) -> String {
        if session.isCodex { return session.sessionId }
        return session.pid.map { String($0) } ?? session.sessionId
    }

    /// Stable grouping key shared by dedup and notification transition guards.
    static func stableKey(for session: Session) -> String {
        if session.isCodex {
            return "codex:\(session.sessionId)"
        }
        if session.hostClass == .desktop {
            return "desktop:\(session.sessionId)"
        }
        return "active:\(displayID(for: session))"
    }

    static func notificationUserInfo(for session: Session) -> [AnyHashable: Any] {
        [
            notificationSessionIDKey: displayID(for: session),
            notificationSessionPIDKey: session.pid.map(String.init) ?? "",
        ]
    }

    static func session(
        matchingNotificationUserInfo userInfo: [AnyHashable: Any],
        in sessions: [Session]
    ) -> Session? {
        if let sessionID = nonEmptyString(userInfo[notificationSessionIDKey]) {
            return sessions.first { displayID(for: $0) == sessionID }
        }

        guard let pid = nonEmptyString(userInfo[notificationSessionPIDKey]) else { return nil }
        return sessions.first {
            displayID(for: $0) == pid || $0.pid.map(String.init) == pid
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// Collapse duplicate display ids during migration, keeping the most recently active copy.
    static func dedupedByDisplayID(_ sessions: [Session]) -> [Session] {
        var byID: [String: Session] = [:]
        for session in sessions {
            let id = displayID(for: session)
            if let existing = byID[id], existing.lastActivity >= session.lastActivity {
                continue
            }
            byID[id] = session
        }
        return byID.values.sorted { displayID(for: $0) < displayID(for: $1) }
    }

    /// Collapse multiple files for one conversation only for hosts with stable conversation identity.
    static func dedupedCandidatesByStableKey(_ candidates: [DedupCandidate]) -> [DedupCandidate] {
        var byKey: [String: DedupCandidate] = [:]
        for candidate in candidates {
            let key = stableKey(for: candidate.session)
            if let existing = byKey[key], SessionLifecyclePolicy.prefers(existing, over: candidate) { continue }
            byKey[key] = candidate
        }
        return byKey.values.sorted { stableKey(for: $0.session) < stableKey(for: $1.session) }
    }
}
