import AppKit
import SwiftUI

struct ManualSessionHideConfirmation: Identifiable, Equatable {
    let identity: SessionIdentityPolicy.LogicalIdentity
    let displayName: String

    init?(identity: SessionIdentityPolicy.LogicalIdentity, displayName: String) {
        guard identity.cctopSessionID != nil else { return nil }
        self.identity = identity
        self.displayName = displayName
    }

    var id: String {
        "hide:\(identity.cctopSessionID ?? "")"
    }

    var title: String {
        "Hide “\(displayName)” from cctop?"
    }

    let message = "It will disappear from the panel, notifications, Navigate mode, and Stream Deck. "
        + "This does not stop or delete the underlying session; cctop will keep it available for lifecycle and Cleanup. "
        + "You cannot show it again while its local session record exists."

    let primaryButtonTitle = "Hide Session"
}

enum PopupConfirmation: Identifiable, Equatable {
    case cleanup(WorktreeRemovalConfirmation)
    case sessionHide(ManualSessionHideConfirmation)

    var id: String {
        switch self {
        case .cleanup(let confirmation):
            return "cleanup:\(confirmation.id)"
        case .sessionHide(let confirmation):
            return "session-hide:\(confirmation.id)"
        }
    }
}

enum PopupOverlay: Equatable {
    case settings, about
}

@MainActor
class OverlayController: ObservableObject {
    @Published var active: PopupOverlay?
    @Published var hideContent = false
}

enum PanelNavAction {
    case up, down, confirm, escape, reset, toggleTab, previousTab, nextTab
}

extension PopupView {
    func openInFinder(path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

// MARK: - Card selection style

struct CardSelectionStyle: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                SelectionSurfaceChrome(
                    isSelected: isSelected,
                    isHovered: isHovered,
                    cornerRadius: cornerRadius
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func cardSelectionStyle(isSelected: Bool, isHovered: Bool, cornerRadius: CGFloat = AppChrome.selectionCornerRadius) -> some View {
        modifier(CardSelectionStyle(isSelected: isSelected, isHovered: isHovered, cornerRadius: cornerRadius))
    }
}

struct SelectionSurfaceChrome: View {
    let isSelected: Bool
    let isHovered: Bool
    let cornerRadius: CGFloat
    var hoverColor = Color.panelSelectionBackground.opacity(0.62)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if isSelected {
                shape.fill(Color.panelSelectionBackground)
            } else if isHovered {
                shape.fill(hoverColor)
            }
        }
    }
}

struct PanelAccentHairline: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(Color.panelAccentBorder, lineWidth: 1)
    }
}

struct PanelSurfaceBackground: View {
    var body: some View {
        Color.panelBackground
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
    var isScanning = false
    var hasAttention = false
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(label)
                    .foregroundStyle(labelForegroundColor)
                if isScanning {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(labelForegroundColor)
                        .frame(width: 10, height: 10)
                        .accessibilityLabel("\(label) scanning")
                } else {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(countForegroundColor)
                    if hasAttention {
                        Circle()
                            .fill(Color.statusAttention)
                            .frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                    }
                }
            }
            .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .allowsTightening(true)
            .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.segmentThumbBackground)
                        .shadow(
                            color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.16),
                            radius: colorScheme == .dark ? 1 : 1.25,
                            y: 1
                        )
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.panelSelectionBackground.opacity(0.62))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var labelForegroundColor: Color {
        if hasAttention { return Color.statusAttentionText }
        if isSelected { return Color.textPrimary }
        return count == 0 ? Color.textMuted.opacity(0.78) : Color.textSecondary
    }

    private var countForegroundColor: Color {
        if hasAttention { return Color.statusAttentionText }
        if isSelected { return Color.textSecondary }
        return Color.textMuted.opacity(count == 0 ? 0.78 : 1)
    }
}

// MARK: - Footer update status

enum FooterUpdateStatusState: Equatable {
    case available(version: String)
    case downloading(version: String)

    var version: String {
        switch self {
        case .available(let version), .downloading(let version):
            return version
        }
    }
}

struct FooterUpdateStatusView: View {
    let state: FooterUpdateStatusState
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        switch state {
        case .available:
            Button(action: action) {
                Text("Update")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentButtonText)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.amber.opacity(isHovered ? 0.90 : 1.0))
                    .clipShape(RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help("Open updater for v\(state.version)")
            .accessibilityLabel("Open cctop updater")
            .accessibilityHint("Opens the updater for cctop v\(state.version).")
        case .downloading:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text("Downloading")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .help("Downloading cctop v\(state.version)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Downloading cctop update")
            .accessibilityHint("cctop v\(state.version) is downloading.")
        }
    }
}

extension PopupView {
    func requestHideSession(_ row: PanelSessionRow) {
        guard let confirmation = ManualSessionHideConfirmation(
            identity: row.userSession.identity,
            displayName: row.session.displayName
        ) else { return }
        pendingConfirmation = .sessionHide(confirmation)
    }

    func confirmationAlert(for confirmation: PopupConfirmation) -> Alert {
        switch confirmation {
        case .cleanup(let cleanupConfirmation):
            return removalAlert(for: cleanupConfirmation)
        case .sessionHide(let sessionConfirmation):
            return sessionHideAlert(for: sessionConfirmation)
        }
    }

    func sessionHideAlert(for confirmation: ManualSessionHideConfirmation) -> Alert {
        Alert(
            title: Text(confirmation.title),
            message: Text(confirmation.message),
            primaryButton: .destructive(Text(confirmation.primaryButtonTitle)) {
                hideSession(confirmation.identity)
            },
            secondaryButton: .cancel()
        )
    }

    func hideSession(_ identity: SessionIdentityPolicy.LogicalIdentity) {
        guard identity.cctopSessionID != nil,
              (userSessions + droppedUserSessions).contains(where: { $0.identity == identity }) else { return }
        onHideSession(identity)
        selectedIndex = nil
        selectedSessionIdentity = nil
    }
}

// MARK: - Panel content wrapper (used by AppDelegate)

struct PanelContentView: View {
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var historyManager: HistoryManager
    @ObservedObject var cleanupManager: WorktreeCleanupManager
    @ObservedObject var cleanupRefreshGate: WorktreeCleanupRefreshGate
    @ObservedObject var updater: UpdaterBase
    @ObservedObject var pluginManager: PluginManager
    @ObservedObject var navigate: NavigateController
    var onOpenUpdater: (() -> Void)?
    var onSelectCleanupRemovalAction: ((WorktreeCleanupCandidate) async -> WorktreeRemovalService.RemovalAction)?
    var onExecuteCleanupRemovalAction: ((WorktreeRemovalService.RemovalAction) async -> WorktreeRemovalService.RemovalResult)?
    var onCleanupTabVisible: () -> Void = {}
    var onCleanupTabHidden: () -> Void = {}
    /// Called (async on main) whenever content layout changes so the host can resize the panel.
    var onLayoutChanged: () -> Void = {}
    @ObservedObject private var themeManager = ThemeManager.shared
    @StateObject private var overlayController = OverlayController()

    var body: some View {
        PopupView(
            userSessions: sessionManager.userSessions,
            acknowledgedSessionIDs: sessionManager.acknowledgedSessionIDs,
            droppedUserSessions: sessionManager.droppedUserSessions,
            recentProjects: historyManager.recentProjects,
            recentResumeTargets: sessionManager.recentResumeTargets,
            cleanupCandidates: cleanupManager.candidates,
            cleanupIsScanning: cleanupManager.isScanning,
            cleanupHasUnseenCandidates: cleanupRefreshGate.hasHiddenCleanupNudge,
            updater: updater,
            pluginManager: pluginManager,
            navigate: navigate,
            overlayController: overlayController,
            onOpenUpdater: onOpenUpdater,
            onAcknowledgeSession: { sessionManager.acknowledgeSession($0) },
            onDropSession: { sessionManager.dropSession($0) },
            onRestoreDroppedSession: { sessionManager.restoreDroppedSession($0) },
            onHideSession: { sessionManager.hideSession($0) },
            onSelectCleanupRemovalAction: onSelectCleanupRemovalAction,
            onExecuteCleanupRemovalAction: onExecuteCleanupRemovalAction,
            onCleanupTabVisible: onCleanupTabVisible,
            onCleanupTabHidden: onCleanupTabHidden,
            onLayoutChanged: onLayoutChanged
        )
        .frame(width: 320)
        .background {
            PanelSurfaceBackground()
        }
        .overlay {
            PanelAccentHairline(cornerRadius: AppChrome.panelCornerRadius)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppChrome.panelCornerRadius, style: .continuous))
        .id(themeManager.themeId)
    }
}

// MARK: - PopupView Previews

/// Inert manager for previews: no home-dir IO, every flag starts false.
@MainActor private func previewPluginManager() -> PluginManager {
    PluginManager(homeDirectory: URL(fileURLWithPath: "/nonexistent"), refreshOnInit: false)
}

/// Runs raw preview fixtures forward through the production record and grouping stages.
private func previewUserSessions(fromDataFixtures dataFixtures: [SessionData]) -> [UserSession] {
    let records = dataFixtures.enumerated().map { index, data in
        SessionRecord(
            data: data,
            lifecycleRank: data.lifecycle.rawValue,
            mtime: .distantPast,
            path: "/preview-session-\(index).json"
        )
    }
    return UserSession.grouping(
        winners: SessionIdentityPolicy.dedupedCandidatesByStableKey(records),
        records: records
    )
}

#Preview("With sessions") {
    PopupView(
        userSessions: previewUserSessions(fromDataFixtures: SessionData.mockSessions),
        updater: DisabledUpdater(),
        pluginManager: previewPluginManager()
    ).frame(width: 320)
}
#Preview("Mixed sources") {
    PopupView(
        userSessions: previewUserSessions(fromDataFixtures: SessionData.qaShowcase),
        updater: DisabledUpdater(),
        pluginManager: previewPluginManager()
    ).frame(width: 320)
}
#Preview("Empty") {
    PopupView(
        userSessions: [], updater: DisabledUpdater(), pluginManager: previewPluginManager()
    ).frame(width: 320)
}
#Preview("With Tabs") {
    PopupView(
        userSessions: previewUserSessions(fromDataFixtures: SessionData.mockSessions),
        recentProjects: RecentProject.mockRecents,
        updater: DisabledUpdater(), pluginManager: previewPluginManager()
    ).frame(width: 320)
}
#Preview("Cleanup") {
    PopupView(
        userSessions: previewUserSessions(fromDataFixtures: SessionData.mockSessions),
        recentProjects: RecentProject.mockRecents,
        cleanupCandidates: WorktreeCleanupCandidate.mockCandidates,
        updater: DisabledUpdater(), pluginManager: previewPluginManager(), initialTab: .cleanup
    ).frame(width: 320)
}
#Preview("Only Recents") {
    PopupView(
        userSessions: [], recentProjects: RecentProject.mockRecents,
        updater: DisabledUpdater(), pluginManager: previewPluginManager()
    ).frame(width: 320)
}
#Preview("Empty Recents Tab") {
    PopupView(
        userSessions: previewUserSessions(fromDataFixtures: SessionData.mockSessions),
        recentProjects: [RecentProject.mock()],
        updater: DisabledUpdater(), pluginManager: previewPluginManager()
    ).frame(width: 320)
}
#Preview("Navigate") {
    let userSessions = previewUserSessions(fromDataFixtures: SessionData.qaShowcase)
    let rc = NavigateController()
    rc.activate(userSessions: SessionDisplayPolicy.activeSessions(from: userSessions))
    return PopupView(
        userSessions: userSessions,
        recentProjects: RecentProject.mockRecents,
        updater: DisabledUpdater(), pluginManager: previewPluginManager(), navigate: rc
    ).frame(width: 320)
}
