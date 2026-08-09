import Foundation

/// Presentation-only grouping for visible retained sessions.
/// This does not change lifecycle or cleanup semantics.
enum SessionDisplayPolicy {
    struct Signature: Equatable {
        let activeIDs: [SessionIdentityPolicy.LogicalIdentity]
        let idleIDs: [SessionIdentityPolicy.LogicalIdentity]

        static let empty = Signature(activeIDs: [], idleIDs: [])
    }

    static let staleIdleInterval: TimeInterval = 172_800 // 48 hours

    static func activeSessions(from sessions: [SessionData], now: Date = Date()) -> [SessionData] {
        sessions.filter { isActive($0, now: now) }
    }

    static func activeSessions(from userSessions: [UserSession], now: Date = Date()) -> [UserSession] {
        userSessions.filter { isActive($0.displayRecord.data, now: now) }
    }

    static func idleSessions(from sessions: [SessionData], now: Date = Date()) -> [SessionData] {
        sessions.filter { isIdle($0, now: now) }
    }

    static func idleSessions(from userSessions: [UserSession], now: Date = Date()) -> [UserSession] {
        userSessions.filter { isIdle($0.displayRecord.data, now: now) }
    }

    /// Keeps Active status groups in priority order while preserving the relative order of peers
    /// that remain in a group. Sessions entering a group append after its surviving members, and
    /// the full-array return value leaves the current non-Active remainder unchanged.
    static func reconcilingActiveOrder(
        in sessions: [SessionData],
        preserving previousSessions: [SessionData],
        now: Date = Date()
    ) -> [SessionData] {
        let active = activeSessions(from: sessions, now: now)
        let activeByKey = Dictionary(
            active.map { (SessionIdentityPolicy.logicalIdentity(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let activeKeys = Set(activeByKey.keys)
        var groups = Array(repeating: [SessionData](), count: SessionStatus.idle.sortOrder + 1)
        var placedKeys: Set<SessionIdentityPolicy.LogicalIdentity> = []

        for previous in activeSessions(from: previousSessions, now: now) {
            let key = SessionIdentityPolicy.logicalIdentity(for: previous)
            guard !placedKeys.contains(key),
                  let current = activeByKey[key],
                  current.status.sortOrder == previous.status.sortOrder else { continue }
            groups[current.status.sortOrder].append(current)
            placedKeys.insert(key)
        }

        for current in active {
            let key = SessionIdentityPolicy.logicalIdentity(for: current)
            guard placedKeys.insert(key).inserted else { continue }
            groups[current.status.sortOrder].append(current)
        }

        let orderedActive = groups.flatMap { $0 }
        let nonActive = sessions.filter { !activeKeys.contains(SessionIdentityPolicy.logicalIdentity(for: $0)) }
        return orderedActive + nonActive
    }

    static func signature(for sessions: [SessionData], now: Date = Date()) -> Signature {
        Signature(
            activeIDs: activeSessions(from: sessions, now: now).map(SessionIdentityPolicy.logicalIdentity),
            idleIDs: idleSessions(from: sessions, now: now).map(SessionIdentityPolicy.logicalIdentity)
        )
    }

    private static func isStaleActiveIdle(_ session: SessionData, now: Date) -> Bool {
        guard session.lifecycle == .active, session.status == .idle else { return false }
        return now.timeIntervalSince(session.lastActivity) > staleIdleInterval
    }

    private static func isIdle(_ session: SessionData, now: Date) -> Bool {
        session.lifecycle == .dormant || isStaleActiveIdle(session, now: now)
    }

    private static func isActive(_ session: SessionData, now: Date) -> Bool {
        session.lifecycle == .active && !isStaleActiveIdle(session, now: now)
    }

}
