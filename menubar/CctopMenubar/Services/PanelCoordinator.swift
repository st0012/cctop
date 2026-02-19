import Foundation

// MARK: - Panel state types

enum PanelMode: Equatable {
    case hidden
    case normal
    case compactCollapsed
    case compactBackgrounded
    case compactExpanded
    case refocus(origin: RefocusOrigin)
}

struct RefocusOrigin: Equatable {
    let panelWasClosed: Bool
    let wasCompact: Bool
}

struct PanelState: Equatable {
    var mode: PanelMode
    var compactPreference: Bool
}

// MARK: - Events & Actions

enum PanelEvent {
    case menubarIconClicked(appIsActive: Bool)
    case cmdM
    case escape
    case headerClicked
    case appLostFocus
    case refocusShortcut
    case refocusConfirmed
    case refocusTimedOut
    case navKey(PanelNavAction)
    case unrecognizedKeyDuringRefocus
}

enum PanelAction: Equatable {
    case showPanel
    case hidePanel
    case refocusPanel
    case positionPanel
    case activateApp
    case deactivateApp
    case startNavKeyMonitor
    case stopNavKeyMonitor
    case postNavAction(PanelNavAction)
    case activateExternalApp
    case restorePreviousApp
    case captureApps
    case startRefocusMode(panelWasClosed: Bool)
    case endRefocusMode
    case startRefocusTimeout
    case persistCompactMode(Bool)
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
            let mode: PanelMode = state.compactPreference ? .compactCollapsed : .normal
            return Result(
                state: PanelState(mode: mode, compactPreference: state.compactPreference),
                actions: [.captureApps, .positionPanel, .showPanel, .activateApp, .startNavKeyMonitor,
                          .postNavAction(.reset)]
            )

        case (.hidden, .refocusShortcut):
            let mode: PanelMode = .refocus(origin: RefocusOrigin(
                panelWasClosed: true,
                wasCompact: state.compactPreference
            ))
            return Result(
                state: PanelState(mode: mode, compactPreference: state.compactPreference),
                actions: [.positionPanel, .showPanel, .activateApp, .startNavKeyMonitor,
                          .startRefocusMode(panelWasClosed: true), .startRefocusTimeout]
            )

        case (.hidden, _):
            return Result(state: state, actions: [], eventConsumed: false)

        // MARK: normal

        case (.normal, .menubarIconClicked(let appIsActive)):
            var actions: [PanelAction] = [.hidePanel, .stopNavKeyMonitor]
            if appIsActive { actions.append(.restorePreviousApp) }
            return Result(
                state: PanelState(mode: .hidden, compactPreference: state.compactPreference),
                actions: actions
            )

        case (.normal, .cmdM):
            return Result(
                state: PanelState(mode: .compactCollapsed, compactPreference: true),
                actions: [.persistCompactMode(true)]
            )

        case (.normal, .escape):
            return Result(state: state, actions: [.postNavAction(.escape)])

        case (.normal, .appLostFocus):
            return Result(state: state, actions: [])

        case (.normal, .refocusShortcut):
            let mode: PanelMode = .refocus(origin: RefocusOrigin(
                panelWasClosed: false,
                wasCompact: false
            ))
            return Result(
                state: PanelState(mode: mode, compactPreference: state.compactPreference),
                actions: [.activateApp, .startRefocusMode(panelWasClosed: false), .startRefocusTimeout]
            )

        case (.normal, .navKey(let action)):
            return Result(state: state, actions: [.postNavAction(action)])

        case (.normal, .headerClicked):
            return Result(state: state, actions: [])

        case (.normal, _):
            return Result(state: state, actions: [], eventConsumed: false)

        // MARK: compactCollapsed

        case (.compactCollapsed, .menubarIconClicked(let appIsActive)):
            var actions: [PanelAction] = [.hidePanel, .stopNavKeyMonitor]
            if appIsActive { actions.append(.restorePreviousApp) }
            return Result(
                state: PanelState(mode: .hidden, compactPreference: state.compactPreference),
                actions: actions
            )

        case (.compactCollapsed, .cmdM):
            return Result(
                state: PanelState(mode: .normal, compactPreference: false),
                actions: [.persistCompactMode(false)]
            )

        case (.compactCollapsed, .escape):
            return Result(
                state: PanelState(mode: .compactBackgrounded, compactPreference: state.compactPreference),
                actions: [.activateExternalApp]
            )

        case (.compactCollapsed, .headerClicked):
            return Result(
                state: PanelState(mode: .compactExpanded, compactPreference: state.compactPreference),
                actions: []
            )

        case (.compactCollapsed, .appLostFocus):
            return Result(
                state: PanelState(mode: .compactBackgrounded, compactPreference: state.compactPreference),
                actions: []
            )

        case (.compactCollapsed, .refocusShortcut):
            let mode: PanelMode = .refocus(origin: RefocusOrigin(
                panelWasClosed: false,
                wasCompact: true
            ))
            return Result(
                state: PanelState(mode: mode, compactPreference: state.compactPreference),
                actions: [.activateApp, .startRefocusMode(panelWasClosed: false), .startRefocusTimeout]
            )

        case (.compactCollapsed, .navKey):
            return Result(state: state, actions: [], eventConsumed: false)

        case (.compactCollapsed, _):
            return Result(state: state, actions: [], eventConsumed: false)

        // MARK: compactBackgrounded

        case (.compactBackgrounded, .menubarIconClicked):
            return Result(
                state: PanelState(mode: .compactCollapsed, compactPreference: state.compactPreference),
                actions: [.refocusPanel, .startNavKeyMonitor]
            )

        case (.compactBackgrounded, .cmdM):
            return Result(
                state: PanelState(mode: .normal, compactPreference: false),
                actions: [.persistCompactMode(false), .refocusPanel, .startNavKeyMonitor]
            )

        case (.compactBackgrounded, .refocusShortcut):
            let mode: PanelMode = .refocus(origin: RefocusOrigin(
                panelWasClosed: false,
                wasCompact: true
            ))
            return Result(
                state: PanelState(mode: mode, compactPreference: state.compactPreference),
                actions: [.activateApp, .refocusPanel, .startNavKeyMonitor,
                          .startRefocusMode(panelWasClosed: false), .startRefocusTimeout]
            )

        case (.compactBackgrounded, .appLostFocus):
            return Result(state: state, actions: [])

        case (.compactBackgrounded, .escape):
            return Result(state: state, actions: [], eventConsumed: false)

        case (.compactBackgrounded, _):
            return Result(state: state, actions: [], eventConsumed: false)

        // MARK: compactExpanded

        case (.compactExpanded, .menubarIconClicked(let appIsActive)):
            var actions: [PanelAction] = [.hidePanel, .stopNavKeyMonitor]
            if appIsActive { actions.append(.restorePreviousApp) }
            return Result(
                state: PanelState(mode: .hidden, compactPreference: state.compactPreference),
                actions: actions
            )

        case (.compactExpanded, .cmdM):
            return Result(
                state: PanelState(mode: .normal, compactPreference: false),
                actions: [.persistCompactMode(false)]
            )

        case (.compactExpanded, .escape):
            return Result(
                state: PanelState(mode: .compactBackgrounded, compactPreference: state.compactPreference),
                actions: [.activateExternalApp]
            )

        case (.compactExpanded, .headerClicked):
            return Result(state: state, actions: [])

        case (.compactExpanded, .appLostFocus):
            return Result(
                state: PanelState(mode: .compactCollapsed, compactPreference: state.compactPreference),
                actions: []
            )

        case (.compactExpanded, .refocusShortcut):
            let mode: PanelMode = .refocus(origin: RefocusOrigin(
                panelWasClosed: false,
                wasCompact: true
            ))
            return Result(
                state: PanelState(mode: mode, compactPreference: state.compactPreference),
                actions: [.activateApp, .startRefocusMode(panelWasClosed: false), .startRefocusTimeout]
            )

        case (.compactExpanded, .navKey(let action)):
            return Result(state: state, actions: [.postNavAction(action)])

        case (.compactExpanded, _):
            return Result(state: state, actions: [], eventConsumed: false)

        // MARK: refocus

        case (.refocus, .menubarIconClicked):
            return endRefocusResult(state: state, restoreFocus: true)

        case (.refocus(let origin), .cmdM):
            let newCompact = !state.compactPreference
            var actions: [PanelAction] = [.endRefocusMode, .persistCompactMode(newCompact)]
            if origin.panelWasClosed {
                actions.append(.hidePanel)
                actions.append(.stopNavKeyMonitor)
            }
            let newMode: PanelMode
            if origin.panelWasClosed {
                newMode = .hidden
            } else {
                newMode = newCompact ? .compactCollapsed : .normal
            }
            return Result(
                state: PanelState(mode: newMode, compactPreference: newCompact),
                actions: actions
            )

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
            actions.append(.hidePanel)
            actions.append(.stopNavKeyMonitor)
        }
        if restoreFocus {
            actions.append(.restorePreviousApp)
        }
        actions.append(.deactivateApp)

        let newMode: PanelMode
        if origin.panelWasClosed {
            newMode = .hidden
        } else if origin.wasCompact {
            newMode = .compactCollapsed
        } else {
            newMode = .normal
        }

        return Result(
            state: PanelState(mode: newMode, compactPreference: state.compactPreference),
            actions: actions
        )
    }
}
