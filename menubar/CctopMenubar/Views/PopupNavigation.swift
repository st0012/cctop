import Foundation

enum PopupTab {
    case active, idle, recent, cleanup

    var helpText: String {
        let staleIdleDuration = Self.staleIdleDurationText
        switch self {
        case .active:
            return "Current sessions; idle moves after \(staleIdleDuration)."
        case .idle:
            return "Dormant sessions and idle sessions over \(staleIdleDuration)."
        case .recent:
            return "Finished work and archived desktop sessions. Rows open the project or app."
        case .cleanup:
            return "Ended-session worktrees checked before removal."
        }
    }

    var emptyStateDetail: String {
        switch self {
        case .active:
            return "Current and recently idle sessions appear here."
        case .idle:
            return "Dormant and long-idle sessions appear here."
        case .recent:
            return "Finished work and archived desktop sessions appear here."
        case .cleanup:
            return "Ended-session worktrees appear here after checks."
        }
    }

    static var cleanupScanningDetail: String {
        "Checking ended-session worktrees."
    }

    static func availableTabs(
        hasIdleSessions: Bool,
        hasRecentProjects _: Bool,
        hasCleanupCandidates: Bool
    ) -> [PopupTab] {
        var tabs: [PopupTab] = [.active]
        if hasIdleSessions { tabs.append(.idle) }
        tabs.append(.recent)
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

    private static var staleIdleDurationText: String {
        let hours = Int(SessionDisplayPolicy.staleIdleInterval / 3_600)
        return "\(hours) hours"
    }
}

struct PopupSelectionContext {
    let activeSessions: [Session]
    let idleSessions: [Session]
    let recentTargets: [RecentResumeTarget]
    let cleanupCandidates: [WorktreeCleanupCandidate]

    init(
        activeSessions: [Session],
        idleSessions: [Session],
        recentProjects: [RecentProject] = [],
        recentResumeTargets: [RecentResumeTarget]? = nil,
        cleanupCandidates: [WorktreeCleanupCandidate]
    ) {
        self.activeSessions = activeSessions
        self.idleSessions = idleSessions
        self.recentTargets = recentResumeTargets ?? recentProjects.map(RecentResumeTarget.project)
        self.cleanupCandidates = cleanupCandidates
    }
}

enum PopupSelectionTarget: Equatable {
    case activeSession(Session)
    case idleSession(Session)
    case recentTarget(RecentResumeTarget)
    case cleanupCandidate(WorktreeCleanupCandidate)

    var confirmsNavigate: Bool {
        switch self {
        case .activeSession, .idleSession, .recentTarget:
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
            guard index < context.recentTargets.count else { return nil }
            return .recentTarget(context.recentTargets[index])
        case .cleanup:
            guard index < context.cleanupCandidates.count else { return nil }
            return .cleanupCandidate(context.cleanupCandidates[index])
        }
    }
}
