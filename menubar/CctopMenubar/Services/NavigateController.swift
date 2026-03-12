import AppKit
import Combine

class NavigateController: ObservableObject {
    @Published var isActive = false
    let didActivateSubject = PassthroughSubject<Void, Never>()
    let didConfirmSubject = PassthroughSubject<Void, Never>()
    let navActionSubject = PassthroughSubject<PanelNavAction, Never>()
    /// Sorted session snapshot captured when navigate activates.
    /// Prevents reordering while badges are visible.
    private(set) var frozenSessions: [Session] = []
    private(set) var previousApp: NSRunningApplication?
    private(set) var panelWasClosedBeforeNavigate = false
    private var timeoutWork: DispatchWorkItem?

    struct DeactivationState {
        let previousApp: NSRunningApplication?
        let panelWasClosed: Bool
    }

    func activate(sessions: [Session]) {
        frozenSessions = Session.sorted(sessions)
        isActive = true
        didActivateSubject.send()
    }

    func activate(sessions: [Session], previousApp: NSRunningApplication?, panelWasClosed: Bool) {
        self.previousApp = previousApp
        self.panelWasClosedBeforeNavigate = panelWasClosed
        activate(sessions: sessions)
    }

    /// Resets all navigate state and returns the state needed for teardown.
    @discardableResult
    func deactivate() -> DeactivationState {
        let state = DeactivationState(
            previousApp: previousApp,
            panelWasClosed: panelWasClosedBeforeNavigate
        )
        isActive = false
        frozenSessions = []
        previousApp = nil
        panelWasClosedBeforeNavigate = false
        cancelTimeout()
        return state
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
