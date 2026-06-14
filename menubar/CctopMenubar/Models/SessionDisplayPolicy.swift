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
}
