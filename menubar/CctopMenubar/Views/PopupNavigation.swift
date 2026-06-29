import Foundation

enum PopupTab {
    case active, idle, recent, cleanup

    static func availableTabs(
        hasIdleSessions: Bool,
        hasRecentProjects: Bool,
        hasCleanupCandidates: Bool
    ) -> [PopupTab] {
        var tabs: [PopupTab] = [.active]
        if hasIdleSessions { tabs.append(.idle) }
        if hasRecentProjects { tabs.append(.recent) }
        tabs.append(.cleanup)
        return tabs
    }

    static func switched(
        from current: PopupTab,
        action: PanelNavAction,
        availableTabs: [PopupTab]
    ) -> PopupTab {
        guard let currentIndex = availableTabs.firstIndex(of: current), !availableTabs.isEmpty else {
            return .active
        }
        switch action {
        case .previousTab:
            return availableTabs[(currentIndex - 1 + availableTabs.count) % availableTabs.count]
        case .nextTab, .toggleTab:
            return availableTabs[(currentIndex + 1) % availableTabs.count]
        default:
            return current
        }
    }
}

struct PopupSelectionContext {
    let activeSessions: [Session]
    let idleSessions: [Session]
    let recentProjects: [RecentProject]
    let cleanupCandidates: [WorktreeCleanupCandidate]
}

enum PopupSelectionTarget: Equatable {
    case activeSession(Session)
    case idleSession(Session)
    case recentProject(RecentProject)
    case cleanupCandidate(WorktreeCleanupCandidate)

    var confirmsNavigate: Bool {
        switch self {
        case .activeSession, .idleSession, .recentProject:
            return true
        case .cleanupCandidate:
            return false
        }
    }

    static func target(
        for tab: PopupTab,
        index: Int,
        in context: PopupSelectionContext
    ) -> PopupSelectionTarget? {
        switch tab {
        case .active:
            guard index < context.activeSessions.count else { return nil }
            return .activeSession(context.activeSessions[index])
        case .idle:
            guard index < context.idleSessions.count else { return nil }
            return .idleSession(context.idleSessions[index])
        case .recent:
            guard index < context.recentProjects.count else { return nil }
            return .recentProject(context.recentProjects[index])
        case .cleanup:
            guard index < context.cleanupCandidates.count else { return nil }
            return .cleanupCandidate(context.cleanupCandidates[index])
        }
    }
}
