import AppKit
import Combine

class JumpModeController: ObservableObject {
    @Published var isActive = false
    /// Sorted session snapshot captured when jump mode activates.
    /// Prevents reordering while badges are visible.
    private(set) var frozenSessions: [Session] = []
    var previousApp: NSRunningApplication?
    var panelWasClosedBeforeJump = false
    private var timeoutWork: DispatchWorkItem?

    func activate(sessions: [Session]) {
        frozenSessions = Session.sorted(sessions)
        isActive = true
    }

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
