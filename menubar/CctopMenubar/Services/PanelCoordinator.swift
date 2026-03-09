import Foundation

// MARK: - Panel state types

/// Panel modes model the distinct behavioral states of the floating panel.
enum PanelMode: Equatable {
    case hidden
    case normal
    case refocus(origin: RefocusOrigin)
}

struct RefocusOrigin: Equatable {
    let panelWasClosed: Bool
}

struct PanelState: Equatable {
    var mode: PanelMode
}

// MARK: - Events & Actions

enum PanelEvent {
    case menubarIconClicked(appIsActive: Bool)
    case escape
    case appLostFocus
    case refocusShortcut
    case refocusConfirmed
    case refocusTimedOut
    case navKey(PanelNavAction)
    case unrecognizedKeyDuringRefocus
}

enum PanelAction: Equatable {
    case showPanel
    case dismissPanel          // hides panel + stops nav key monitor
    case refocusPanel
    case positionPanel
    case activateApp
    case deactivateApp
    case startNavKeyMonitor
    case postNavAction(PanelNavAction)
    case activateExternalApp
    case restorePreviousApp
    case captureApps
    case startRefocusMode(panelWasClosed: Bool)
    case endRefocusMode
}

// MARK: - Pure coordinator

struct PanelCoordinator {
    struct Result: Equatable {
        let state: PanelState
        let actions: [PanelAction]
        let eventConsumed: Bool

        init(state: PanelState, actions: [PanelAction], eventConsumed: Bool = true) {
            self.state = state
            self.actions = actions
            self.eventConsumed = eventConsumed
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func handle(event: PanelEvent, state: PanelState) -> Result {
        switch (state.mode, event) {

        // MARK: hidden

        case (.hidden, .menubarIconClicked):
            return Result(
                state: PanelState(mode: .normal),
                actions: [.captureApps, .positionPanel, .showPanel, .activateApp, .startNavKeyMonitor,
                          .postNavAction(.reset)]
            )

        case (.hidden, .refocusShortcut):
            let mode: PanelMode = .refocus(origin: RefocusOrigin(panelWasClosed: true))
            return Result(
                state: PanelState(mode: mode),
                actions: [.positionPanel, .showPanel, .activateApp, .startNavKeyMonitor,
                          .startRefocusMode(panelWasClosed: true)]
            )

        case (.hidden, _):
            return Result(state: state, actions: [], eventConsumed: false)

        // MARK: normal

        case (.normal, .menubarIconClicked(let appIsActive)):
            var actions: [PanelAction] = [.dismissPanel]
            if appIsActive { actions.append(.restorePreviousApp) }
            return Result(
                state: PanelState(mode: .hidden),
                actions: actions
            )

        case (.normal, .escape):
            return Result(state: state, actions: [.postNavAction(.escape)])

        case (.normal, .appLostFocus):
            return Result(state: state, actions: [])

        case (.normal, .refocusShortcut):
            let mode: PanelMode = .refocus(origin: RefocusOrigin(panelWasClosed: false))
            return Result(
                state: PanelState(mode: mode),
                actions: [.activateApp, .startRefocusMode(panelWasClosed: false)]
            )

        case (.normal, .navKey(let action)):
            return Result(state: state, actions: [.postNavAction(action)])

        case (.normal, _):
            return Result(state: state, actions: [], eventConsumed: false)

        // MARK: refocus

        case (.refocus, .menubarIconClicked):
            return endRefocusResult(state: state, restoreFocus: true)

        case (.refocus, .escape):
            return endRefocusResult(state: state, restoreFocus: true)

        case (.refocus, .appLostFocus):
            return endRefocusResult(state: state, restoreFocus: false)

        case (.refocus, .refocusConfirmed):
            return endRefocusResult(state: state, restoreFocus: false)

        case (.refocus, .refocusTimedOut):
            return endRefocusResult(state: state, restoreFocus: true)

        case (.refocus, .navKey(let action)):
            return Result(state: state, actions: [.postNavAction(action)])

        case (.refocus, .unrecognizedKeyDuringRefocus):
            return endRefocusResult(state: state, restoreFocus: true)

        case (.refocus, _):
            return Result(state: state, actions: [], eventConsumed: false)
        }
    }

    // MARK: - Helpers

    private static func endRefocusResult(state: PanelState, restoreFocus: Bool) -> Result {
        guard case .refocus(let origin) = state.mode else {
            return Result(state: state, actions: [])
        }

        var actions: [PanelAction] = [.endRefocusMode]
        if origin.panelWasClosed {
            actions.append(.dismissPanel)
        }
        if restoreFocus {
            actions.append(.activateExternalApp)
        } else {
            actions.append(.deactivateApp)
        }

        let newMode: PanelMode = origin.panelWasClosed ? .hidden : .normal

        return Result(
            state: PanelState(mode: newMode),
            actions: actions
        )
    }
}
