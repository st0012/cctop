import Combine
import Foundation

class NavigateController: ObservableObject {
    @Published var isActive = false
    let didActivateSubject = PassthroughSubject<Void, Never>()
    let didConfirmSubject = PassthroughSubject<Void, Never>()
    let navActionSubject = PassthroughSubject<PanelNavAction, Never>()
    /// Sorted session snapshot captured when navigate activates.
    /// Prevents reordering while badges are visible.
    private(set) var frozenSessions: [Session] = []
    private var timeoutWork: DispatchWorkItem?

    func activate(sessions: [Session]) {
        frozenSessions = Session.sorted(sessions)
        isActive = true
        didActivateSubject.send()
    }

    /// Resets all navigate state.
    func deactivate() {
        isActive = false
        frozenSessions = []
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
