import Foundation

enum SessionIdentityPolicy {
    /// File-local host classification. Deliberately strict: `source` never classifies desktop
    /// vs CLI because both integrations share source strings with their desktop counterparts.
    static func hostClass(for session: Session) -> SessionHostClass {
        if let app = HostApp.from(bundleIdentifier: session.terminal?.bundleId) {
            return app.isDesktopApp ? .desktop : .terminal
        }
        if session.terminal?.multiplexer != nil { return .terminal }
        return .ambiguous
    }

    /// UI identity. Codex multiplexes many conversations onto one host process, so its PID is
    /// not unique per conversation; every other source keeps the existing PID identity.
    static func displayID(for session: Session) -> String {
        if session.isCodex { return session.sessionId }
        return session.pid.map { String($0) } ?? session.sessionId
    }

    /// Durable file identity. Codex uses session_id to avoid shared-PID collisions and to avoid
    /// legacy UUID-file cleanup; other sources remain PID-keyed.
    static func fileName(harnessName: String?, pid: UInt32, safeSessionId: String) -> String {
        if harnessName == Session.codexSource {
            return "codex-\(safeSessionId).json"
        }
        return "\(pid).json"
    }

    /// Stable grouping key shared by dedup and notification transition guards.
    static func stableKey(for session: Session) -> String {
        if session.isCodex {
            return "codex:\(session.sessionId)"
        }
        if hostClass(for: session) == .desktop {
            return "desktop:\(session.sessionId)"
        }
        return "active:\(displayID(for: session))"
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
