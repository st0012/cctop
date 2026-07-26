import Foundation

/// Presentation-only grouping for visible retained sessions.
/// This does not change lifecycle or cleanup semantics.
enum SessionDisplayPolicy {
    struct Signature: Equatable {
        let activeIDs: [String]
        let idleIDs: [String]

        static let empty = Signature(activeIDs: [], idleIDs: [])
    }

    static let staleIdleInterval: TimeInterval = 172_800 // 48 hours

    static func activeSessions(from sessions: [Session], now: Date = Date()) -> [Session] {
        sessions.filter { session in
            session.lifecycle == .active && !isStaleActiveIdle(session, now: now)
        }
    }

    static func idleSessions(from sessions: [Session], now: Date = Date()) -> [Session] {
        sessions.filter { session in
            session.lifecycle == .dormant || isStaleActiveIdle(session, now: now)
        }
    }

    /// Returns the full session array with surviving Active sessions in their published order,
    /// newcomers appended, and the non-Active remainder untouched. The initial/newcomer order
    /// matches the legacy status-and-recency presentation order, with stable identity as a tie-breaker.
    static func reconcilingActiveOrder(
        in sessions: [Session],
        preserving previousSessions: [Session],
        now: Date = Date()
    ) -> [Session] {
        let active = activeSessions(from: sessions, now: now)
        let activeByKey = Dictionary(
            active.map { (SessionIdentityPolicy.stableKey(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let activeKeys = Set(activeByKey.keys)
        let retainedKeys = activeSessions(from: previousSessions, now: now)
            .map { SessionIdentityPolicy.stableKey(for: $0) }
            .filter(activeKeys.contains)
        let retainedKeySet = Set(retainedKeys)
        let newcomerKeys = activeKeys
            .subtracting(retainedKeySet)
            .sorted { lhsKey, rhsKey in
                guard let lhs = activeByKey[lhsKey], let rhs = activeByKey[rhsKey] else {
                    return lhsKey < rhsKey
                }
                return initialActiveOrder(lhs, precedes: rhs)
            }
        let orderedActive = (retainedKeys + newcomerKeys).compactMap { activeByKey[$0] }
        let nonActive = sessions.filter { !activeKeys.contains(SessionIdentityPolicy.stableKey(for: $0)) }
        return orderedActive + nonActive
    }

    static func signature(for sessions: [Session], now: Date = Date()) -> Signature {
        Signature(
            activeIDs: activeSessions(from: sessions, now: now).map(\.id),
            idleIDs: idleSessions(from: sessions, now: now).map(\.id)
        )
    }

    private static func isStaleActiveIdle(_ session: Session, now: Date) -> Bool {
        guard session.lifecycle == .active, session.status == .idle else { return false }
        return now.timeIntervalSince(session.lastActivity) > staleIdleInterval
    }

    private static func initialActiveOrder(_ lhs: Session, precedes rhs: Session) -> Bool {
        if lhs.status.sortOrder != rhs.status.sortOrder {
            return lhs.status.sortOrder < rhs.status.sortOrder
        }
        if lhs.lastActivity != rhs.lastActivity {
            return lhs.lastActivity > rhs.lastActivity
        }
        return SessionIdentityPolicy.stableKey(for: lhs) < SessionIdentityPolicy.stableKey(for: rhs)
    }
}
