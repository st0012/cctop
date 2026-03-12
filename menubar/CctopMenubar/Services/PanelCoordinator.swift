import Foundation

// MARK: - Panel state types

/// Panel modes model the distinct behavioral states of the floating panel.
enum PanelMode: Equatable {
    case hidden
    case normal
    case navigate(origin: NavigateOrigin)
}

struct NavigateOrigin: Equatable {
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
    case navigateShortcut
    case navigateConfirmed
    case navigateTimedOut
    case navKey(PanelNavAction)
    case unrecognizedKeyDuringNavigate
}

enum PanelAction: Equatable {
    case showPanel
    case dismissPanel          // hides panel + stops nav key monitor
    case navigatePanel
    case positionPanel
    case activateApp
    case deactivateApp
    case startNavKeyMonitor
    case postNavAction(PanelNavAction)
    case activateExternalApp
    case restorePreviousApp
    case captureApps
    case startNavigateMode(panelWasClosed: Bool)
    case endNavigateMode
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

        case (.hidden, .navigateShortcut):
            let mode: PanelMode = .navigate(origin: NavigateOrigin(panelWasClosed: true))
            return Result(
                state: PanelState(mode: mode),
                actions: [.positionPanel, .showPanel, .activateApp, .startNavKeyMonitor,
                          .startNavigateMode(panelWasClosed: true)]
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

        case (.normal, .navigateShortcut):
            let mode: PanelMode = .navigate(origin: NavigateOrigin(panelWasClosed: false))
            return Result(
                state: PanelState(mode: mode),
                actions: [.activateApp, .startNavigateMode(panelWasClosed: false)]
            )

        case (.normal, .navKey(let action)):
            return Result(state: state, actions: [.postNavAction(action)])

        case (.normal, _):
            return Result(state: state, actions: [], eventConsumed: false)

        // MARK: navigate

        case (.navigate, .menubarIconClicked):
            return endNavigateResult(state: state, restoreFocus: true)

        case (.navigate, .escape):
            return endNavigateResult(state: state, restoreFocus: true)

        case (.navigate, .appLostFocus):
            return endNavigateResult(state: state, restoreFocus: false)

        case (.navigate, .navigateConfirmed):
            return endNavigateResult(state: state, restoreFocus: false)

        case (.navigate, .navigateTimedOut):
            return endNavigateResult(state: state, restoreFocus: true)

        case (.navigate, .navKey(let action)):
            return Result(state: state, actions: [.postNavAction(action)])

        case (.navigate, .unrecognizedKeyDuringNavigate):
            return endNavigateResult(state: state, restoreFocus: true)

        case (.navigate, _):
            return Result(state: state, actions: [], eventConsumed: false)
        }
    }

    // MARK: - Helpers

    private static func endNavigateResult(state: PanelState, restoreFocus: Bool) -> Result {
        guard case .navigate(let origin) = state.mode else {
            return Result(state: state, actions: [])
        }

        var actions: [PanelAction] = [.endNavigateMode]
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
