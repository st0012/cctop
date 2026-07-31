import Foundation

enum FocusTargetResolver {
    /// Resolve a permanent logical id to the first matching current observation.
    /// The caller supplies focus-eligible observations in canonical panel order.
    static func currentSession(forCctopSessionID cctopSessionID: String, in observations: [Session]) -> Session? {
        guard Session.isValidCctopSessionId(cctopSessionID) else { return nil }
        return observations.first { $0.cctopSessionId == cctopSessionID }
    }

    /// Resolve panel/navigation identity against current observations. Permanent IDs use
    /// the canonical first-match policy; legacy keys remain usable only when unambiguous.
    static func currentSession(
        for identity: SessionIdentityPolicy.LogicalIdentity,
        in observations: [Session]
    ) -> Session? {
        if let cctopSessionID = identity.cctopSessionID {
            return currentSession(forCctopSessionID: cctopSessionID, in: observations)
        }

        guard case .legacy(let stableKey) = identity else { return nil }
        let matches = observations.filter { SessionIdentityPolicy.stableKey(for: $0) == stableKey }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}
