import Foundation

enum FocusTargetResolver {
    /// Resolve a permanent logical id to the first matching current observation.
    /// The caller supplies focus-eligible observations in canonical panel order.
    static func currentSession(forCctopSessionID cctopSessionID: String, in observations: [Session]) -> Session? {
        guard Session.isValidCctopSessionId(cctopSessionID) else { return nil }
        return observations.first { $0.cctopSessionId == cctopSessionID }
    }
}
