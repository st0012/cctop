import Combine
import Foundation

class NavigateController: ObservableObject {
    @Published var isActive = false
    let didActivateSubject = PassthroughSubject<Void, Never>()
    let didConfirmSubject = PassthroughSubject<Void, Never>()
    let navActionSubject = PassthroughSubject<PanelNavAction, Never>()
    /// Canonically ordered logical identities captured when navigate activates.
    /// Array positions remain the numbered slots even when an observation disappears.
    private(set) var frozenSessionIdentities: [SessionIdentityPolicy.LogicalIdentity] = []
    var activeSessionIdentitySnapshot: [SessionIdentityPolicy.LogicalIdentity]? {
        isActive ? frozenSessionIdentities : nil
    }
    private var timeoutWork: DispatchWorkItem?

    func activate(sessions: [Session]) {
        frozenSessionIdentities = sessions.map(SessionIdentityPolicy.logicalIdentity)
        isActive = true
        didActivateSubject.send()
    }

    func sessionIdentity(at index: Int) -> SessionIdentityPolicy.LogicalIdentity? {
        guard isActive, frozenSessionIdentities.indices.contains(index) else { return nil }
        return frozenSessionIdentities[index]
    }

    /// Resets all navigate state.
    func deactivate() {
        isActive = false
        frozenSessionIdentities = []
        cancelTimeout()
    }

    func startTimeout(duration: TimeInterval = 5, onTimeout: @escaping () -> Void) {
        cancelTimeout()
        let work = DispatchWorkItem { [weak self] in
            guard self?.isActive == true else { return }
            onTimeout()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func cancelTimeout() {
        timeoutWork?.cancel()
        timeoutWork = nil
    }
}
