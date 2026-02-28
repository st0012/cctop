import SwiftUI

enum PanelNavAction {
    case up, down, confirm, escape, reset, toggleTab, previousTab, nextTab
}

// MARK: - Card selection style

struct CardSelectionStyle: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(borderColor, lineWidth: 1)
            )
    }

    private var backgroundColor: Color {
        if isSelected { return Color.amber.opacity(0.10) }
        if isHovered { return Color.primary.opacity(0.06) }
        return Color.cardBackground
    }

    private var borderColor: Color {
        if isSelected { return Color.amber.opacity(0.4) }
        if isHovered { return Color.primary.opacity(0.15) }
        return Color.cardBorder
    }
}

extension View {
    func cardSelectionStyle(isSelected: Bool, isHovered: Bool, cornerRadius: CGFloat = 10) -> some View {
        modifier(CardSelectionStyle(isSelected: isSelected, isHovered: isHovered, cornerRadius: cornerRadius))
    }
}

// MARK: - Roll-up animation

struct RollUpEffect: ViewModifier {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.mask {
            Color.black.scaleEffect(y: progress, anchor: .top)
        }
    }
}

struct TabButtonView: View {
    let label: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.amber : Color.textMuted)
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? Color.amber : Color.textMuted)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.amber.opacity(0.15) : Color.primary.opacity(0.06))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isSelected || isHovered ? Color.primary.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Panel content wrapper (used by AppDelegate)

struct PanelContentView: View {
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var historyManager: HistoryManager
    @ObservedObject var updater: UpdaterBase
    @ObservedObject var pluginManager: PluginManager
    @ObservedObject var refocus: RefocusController
    @ObservedObject var compactController: CompactModeController

    var body: some View {
        PopupView(
            sessions: sessionManager.sessions,
            recentProjects: historyManager.recentProjects,
            updater: updater,
            pluginManager: pluginManager,
            refocus: refocus,
            isCompact: compactController.isCompact,
            isCompactModeEnabled: compactController.compactMode,
            onExpand: {
                NotificationCenter.default.post(name: .panelHeaderClicked, object: nil)
            }
        )
        .frame(width: 320)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - PopupView Previews

#Preview("With sessions") {
    PopupView(sessions: Session.mockSessions, updater: DisabledUpdater()).frame(width: 320)
}
#Preview("Mixed sources") {
    PopupView(sessions: Session.qaShowcase, updater: DisabledUpdater()).frame(width: 320)
}
#Preview("Empty") {
    PopupView(sessions: [], updater: DisabledUpdater(), pluginManager: PluginManager()).frame(width: 320)
}
#Preview("With Tabs") {
    PopupView(
        sessions: Session.mockSessions, recentProjects: RecentProject.mockRecents, updater: DisabledUpdater()
    ).frame(width: 320)
}
#Preview("Only Recents") {
    PopupView(
        sessions: [], recentProjects: RecentProject.mockRecents,
        updater: DisabledUpdater(), pluginManager: PluginManager()
    ).frame(width: 320)
}
#Preview("Empty Recents Tab") {
    PopupView(
        sessions: Session.mockSessions, recentProjects: [RecentProject.mock()], updater: DisabledUpdater()
    ).frame(width: 320)
}
#Preview("Refocus") {
    let rc = RefocusController(); rc.isActive = true
    return PopupView(
        sessions: Session.qaShowcase, recentProjects: RecentProject.mockRecents,
        updater: DisabledUpdater(), refocus: rc
    ).frame(width: 320)
}
#Preview("Compact") {
    PopupView(
        sessions: Session.qaShowcase, updater: DisabledUpdater(),
        isCompact: true, isCompactModeEnabled: true
    ).frame(width: 320)
}
#Preview("Compact Expanded") {
    PopupView(
        sessions: Session.qaShowcase, updater: DisabledUpdater(),
        isCompactModeEnabled: true
    ).frame(width: 320)
}
