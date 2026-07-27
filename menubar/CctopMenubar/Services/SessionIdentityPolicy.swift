import Foundation

enum SessionIdentityPolicy {
    static let notificationSessionIDKey = "sessionID"
    static let notificationSessionPIDKey = "sessionPID"

    /// Stable grouping key shared by dedup and notification transition guards.
    static func stableKey(for session: Session) -> String {
        if session.isCodex {
            return "codex:\(session.sessionId)"
        }
        if session.hostClass == .desktop {
            return "desktop:\(session.sessionId)"
        }
        return "active:\(session.id)"
    }

    static func notificationRequestIdentifier(for session: Session) -> String {
        "session-\(stableKey(for: session))"
    }

    static func notificationUserInfo(for session: Session) -> [AnyHashable: Any] {
        [
            notificationSessionIDKey: notificationSessionID(for: session),
            notificationSessionPIDKey: session.pid.map(String.init) ?? "",
        ]
    }

    static func session(
        matchingNotificationUserInfo userInfo: [AnyHashable: Any],
        in sessions: [Session]
    ) -> Session? {
        if let sessionID = nonEmptyString(userInfo[notificationSessionIDKey]) {
            if let match = sessions.first(where: { notificationSessionID(for: $0) == sessionID }) {
                return match
            }
            return sessions.first { $0.id == sessionID }
        }

        guard let pid = nonEmptyString(userInfo[notificationSessionPIDKey]) else { return nil }
        return sessions.first {
            $0.id == pid || $0.pid.map(String.init) == pid
        }
    }

    /// Match a session by the permanent cctop-owned id published to external control
    /// surfaces. Exact match only. When several live observations share one logical id,
    /// canonical SessionManager order selects the currently associated focus target.
    static func session(matchingCctopSessionID cctopSessionID: String, in sessions: [Session]) -> Session? {
        sessions.first { $0.cctopSessionId == cctopSessionID }
    }

    private static func notificationSessionID(for session: Session) -> String {
        if session.isCodex || session.hostClass == .desktop {
            return session.sessionId
        }
        return session.id
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// Collapse duplicate display ids during migration, keeping the most recently active copy.
    static func dedupedByDisplayID(_ sessions: [Session]) -> [Session] {
        var byID: [String: Session] = [:]
        for session in sessions {
            let id = session.id
            if let existing = byID[id], existing.lastActivity >= session.lastActivity {
                continue
            }
            byID[id] = session
        }
        return byID.values.sorted { $0.id < $1.id }
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
