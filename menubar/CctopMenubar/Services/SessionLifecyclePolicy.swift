import Foundation

/// Ordering inputs for lifecycle deduplication, kept separate from `Session`'s stored fields
/// so the total order is unit-testable without disk or process probing. `mtime` is
/// `.distantPast` when unknown so the comparison stays total.
struct DedupCandidate {
    let session: Session
    let lifecycleRank: Int   // 0 = active, 1 = dormant, 2 = finished (lower = preferred)
    let mtime: Date
    let path: String         // absolute file path; final, total tiebreak
}

/// Tunable windows for lifecycle derivation.
struct LifecycleWindows {
    let active: TimeInterval     // Codex Desktop "recent activity counts as active" threshold
    let retention: TimeInterval  // dormant desktop -> finished age-out from disconnected_at
}

enum SessionConnectionState: Equatable {
    case connected
    case disconnected
}

enum SessionLifecyclePolicy {
    /// Pure connection derivation. Every host class goes through this same first step:
    /// decide whether the session record still represents a connected session.
    static func connectionState(
        for session: Session, hostClass: SessionHostClass, processAlive: Bool,
        now: Date, windows: LifecycleWindows
    ) -> SessionConnectionState {
        if session.endedAt != nil { return .disconnected }
        // The shared-PID recency carve-out is Codex Desktop's, identified by source ("codex") OR by
        // the trusted Codex Desktop bundle id — the latter covers pre-harness-migration files whose
        // source is nil, which would otherwise fall back to (unreliable, shared) PID liveness.
        let useRecency = hostClass == .desktop && (session.isCodex || session.isCodexDesktopHost)
        let connected = useRecency ? (now.timeIntervalSince(session.lastActivity) < windows.active) : processAlive
        return connected ? .connected : .disconnected
    }

    /// Pure lifecycle derivation. Connection is detected uniformly first; host policy then
    /// decides what disconnected means for desktop versus non-desktop sessions.
    static func lifecycle(
        for session: Session, hostClass: SessionHostClass, processAlive: Bool,
        now: Date, windows: LifecycleWindows
    ) -> SessionLifecycle {
        let connection = connectionState(
            for: session, hostClass: hostClass, processAlive: processAlive, now: now, windows: windows
        )
        if connection == .connected { return .active }
        guard hostClass == .desktop else { return .finished }
        guard let disconnectedAt = session.disconnectedAt else { return .dormant }
        return now.timeIntervalSince(disconnectedAt) <= windows.retention ? .dormant : .finished
    }

    static func prefers(_ lhs: DedupCandidate, over rhs: DedupCandidate) -> Bool {
        if lhs.lifecycleRank != rhs.lifecycleRank { return lhs.lifecycleRank < rhs.lifecycleRank }
        if lhs.session.lastActivity != rhs.session.lastActivity {
            return lhs.session.lastActivity > rhs.session.lastActivity
        }
        if lhs.session.effectiveEndDate != rhs.session.effectiveEndDate {
            return lhs.session.effectiveEndDate > rhs.session.effectiveEndDate
        }
        if lhs.mtime != rhs.mtime { return lhs.mtime > rhs.mtime }
        return lhs.path < rhs.path
    }
}
