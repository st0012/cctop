import CryptoKit
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

    /// Opaque, deterministic identity for acting on one live focus target from an
    /// external control surface (Stream Deck keys, `cctop://focus`). It combines the
    /// integration's exact session reference with process-generation identity, so two
    /// visible processes hosting the same conversation still receive different ids.
    /// Deliberately separate from `stableKey`: this is a short-lived routing token, not
    /// canonical session identity or a persistence key.
    static func actionID(for session: Session) -> String {
        hashedActionID(components: actionIdentityComponents(for: session))
    }

    private static func actionIdentityComponents(for session: Session) -> [String] {
        let source = session.source ?? Session.ccSource
        let sessionReference = session.harnessSessionId.flatMap { $0.isEmpty ? nil : $0 } ?? session.sessionId
        var components = ["action", source, sessionReference]
        if let pid = session.pid {
            let start = session.pidStartTime.map { String(format: "%.6f", $0) } ?? ""
            components.append(contentsOf: ["process", String(pid), start])
        } else {
            // Records without process metadata are uncommon and cannot name a separate
            // process generation; retain their existing row identity as the fallback.
            components.append(contentsOf: ["record", session.id])
        }
        return components
    }

    /// Netstring-style length prefixes make the encoding injective: no combination of
    /// component values can collide with a different component split. 128-bit truncation
    /// keeps the token short while staying far beyond collision range for local sessions.
    private static func hashedActionID(components: [String]) -> String {
        let canonical = components.map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "s-\(hex)"
    }

    /// Match a session by the opaque action id published to external control surfaces.
    /// Exact match only — pre-action-id published values (raw pid strings) are deliberately
    /// not aliased, because a recycled PID could focus an unrelated session; a stale
    /// pre-upgrade command simply finds nothing.
    static func session(matchingDisplayID displayID: String, in sessions: [Session]) -> Session? {
        sessions.first { actionID(for: $0) == displayID }
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
