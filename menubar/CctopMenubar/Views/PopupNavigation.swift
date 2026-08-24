import Foundation
import SwiftUI

enum PopupTab: CaseIterable, Hashable {
    case active, idle, acknowledged, dropped, recent, cleanup

    static let primaryCases: [PopupTab] = [.active, .idle, .acknowledged, .dropped]
    static let secondaryCases: [PopupTab] = [.recent, .cleanup]

    var label: String {
        switch self {
        case .active: return "Active"
        case .idle: return "Idle"
        case .acknowledged: return "Ack"
        case .dropped: return "Dropped"
        case .recent: return "Recent"
        case .cleanup: return "Cleanup"
        }
    }

    var helpText: String {
        let staleIdleDuration = Self.staleIdleDurationText
        switch self {
        case .active:
            return "Current sessions; idle moves after \(staleIdleDuration)."
        case .idle:
            return "Dormant sessions and idle sessions over \(staleIdleDuration)."
        case .acknowledged:
            return "Acknowledged sessions; newer attention clears the acknowledgement."
        case .dropped:
            return "Sessions removed from normal surfaces until restored or newer activity."
        case .recent:
            return "Finished work and archived desktop sessions. Rows open the project or app when possible."
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
        case .acknowledged:
            return "Acknowledged sessions appear here until they report newer attention."
        case .dropped:
            return "Dropped sessions appear here until restored or they report newer activity."
        case .recent:
            return "Finished work and archived desktop sessions appear here."
        case .cleanup:
            return "Ended-session worktrees appear here after checks."
        }
    }

    static var cleanupScanningDetail: String {
        "Checking ended-session worktrees."
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

struct SecondaryTabMenuView: View {
    let selectedTab: PopupTab
    let cleanupIsScanning: Bool
    let cleanupHasAttention: Bool
    let count: (PopupTab) -> Int
    let onSelect: (PopupTab) -> Void

    private var isSelected: Bool {
        PopupTab.secondaryCases.contains(selectedTab)
    }

    var body: some View {
        Menu {
            ForEach(PopupTab.secondaryCases, id: \.self) { tab in
                Button {
                    onSelect(tab)
                } label: {
                    Text(menuLabel(for: tab))
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                if cleanupIsScanning {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(isSelected ? Color.textPrimary : Color.textSecondary)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                }
                if cleanupHasAttention && selectedTab != .cleanup {
                    Circle()
                        .fill(Color.statusAttention)
                        .frame(width: 5, height: 5)
                        .offset(x: 5, y: -3)
                }
            }
            .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
            .frame(width: 28, height: 22)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.segmentThumbBackground)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .help("Recent and Cleanup")
        .accessibilityLabel("More views")
        .accessibilityValue(isSelected ? selectedTab.label : "")
    }

    private func menuLabel(for tab: PopupTab) -> String {
        if tab == .cleanup && cleanupIsScanning {
            return "Cleanup checking"
        }
        return "\(tab.label) \(count(tab))"
    }
}

struct PopupSelectionContext {
    let recentTargets: [RecentResumeTarget]
    let cleanupCandidates: [WorktreeCleanupCandidate]

    init(
        recentProjects: [RecentProject] = [],
        recentResumeTargets: [RecentResumeTarget]? = nil,
        cleanupCandidates: [WorktreeCleanupCandidate]
    ) {
        self.recentTargets = recentResumeTargets ?? recentProjects.map(RecentResumeTarget.project)
        self.cleanupCandidates = cleanupCandidates
    }
}

enum PopupSelectionTarget: Equatable {
    case recentTarget(RecentResumeTarget)
    case cleanupCandidate(WorktreeCleanupCandidate)

    var confirmsNavigate: Bool {
        switch self {
        case .recentTarget:
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
        case .active, .idle, .acknowledged, .dropped:
            return nil
        case .recent:
            guard index < context.recentTargets.count else { return nil }
            return .recentTarget(context.recentTargets[index])
        case .cleanup:
            guard index < context.cleanupCandidates.count else { return nil }
            return .cleanupCandidate(context.cleanupCandidates[index])
        }
    }
}
