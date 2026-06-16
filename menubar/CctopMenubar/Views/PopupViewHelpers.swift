import AppKit
import SwiftUI

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
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.panelAccentBorder, lineWidth: 1)
                }
            }
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
                shape.fill(selectionHighlight)
            } else if isHovered {
                shape.fill(hoverColor)
            }
        }
    }

    private var selectionHighlight: LinearGradient {
        LinearGradient(
            colors: [Color.selectionHighlightOverlay, Color.clear],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct PanelAccentHairline: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(accentGradient, lineWidth: 1)
    }

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.panelAccentBorder,
                Color.panelControlBorder,
                Color.statusGreen.opacity(0.08),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct PanelMaterialView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.isEmphasized = false
    }
}

struct PanelTintBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.panelBackground.opacity(panelBackgroundOpacity)
            Color.panelMaterialOverlay.opacity(panelOverlayOpacity)
        }
    }

    private var panelBackgroundOpacity: Double {
        colorScheme == .dark ? 0.72 : 0.58
    }

    private var panelOverlayOpacity: Double {
        colorScheme == .dark ? 0.72 : 0.55
    }
}

struct PanelSurfaceBackground: View {
    var usesMaterial = true

    var body: some View {
        ZStack {
            if usesMaterial {
                PanelMaterialView()
            }
            PanelTintBackground()
        }
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
                    .foregroundStyle(isSelected ? Color.textPrimary : Color.textMuted)
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? Color.textPrimary : Color.textMuted)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.panelControlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                SelectionSurfaceChrome(
                    isSelected: isSelected,
                    isHovered: isHovered,
                    cornerRadius: AppChrome.controlCornerRadius,
                    hoverColor: Color.panelControlBackground
                )
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous)
                        .stroke(Color.panelAccentBorder, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Panel content wrapper (used by AppDelegate)

struct PanelContentView: View {
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var historyManager: HistoryManager
    @ObservedObject var updater: UpdaterBase
    @ObservedObject var pluginManager: PluginManager
    @ObservedObject var navigate: NavigateController
    /// Called (async on main) whenever content layout changes so the host can resize the panel.
    var onLayoutChanged: () -> Void = {}
    @ObservedObject private var themeManager = ThemeManager.shared
    @StateObject private var overlayController = OverlayController()

    var body: some View {
        PopupView(
            sessions: sessionManager.sessions,
            recentProjects: historyManager.recentProjects,
            updater: updater,
            pluginManager: pluginManager,
            navigate: navigate,
            overlayController: overlayController,
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

#Preview("With sessions") {
    PopupView(
        sessions: Session.mockSessions, updater: DisabledUpdater(), pluginManager: previewPluginManager()
    ).frame(width: 320)
}
#Preview("Mixed sources") {
    PopupView(
        sessions: Session.qaShowcase, updater: DisabledUpdater(), pluginManager: previewPluginManager()
    ).frame(width: 320)
}
#Preview("Empty") {
    PopupView(
        sessions: [], updater: DisabledUpdater(), pluginManager: previewPluginManager()
    ).frame(width: 320)
}
#Preview("With Tabs") {
    PopupView(
        sessions: Session.mockSessions, recentProjects: RecentProject.mockRecents,
        updater: DisabledUpdater(), pluginManager: previewPluginManager()
    ).frame(width: 320)
}
#Preview("Only Recents") {
    PopupView(
        sessions: [], recentProjects: RecentProject.mockRecents,
        updater: DisabledUpdater(), pluginManager: previewPluginManager()
    ).frame(width: 320)
}
#Preview("Empty Recents Tab") {
    PopupView(
        sessions: Session.mockSessions, recentProjects: [RecentProject.mock()],
        updater: DisabledUpdater(), pluginManager: previewPluginManager()
    ).frame(width: 320)
}
#Preview("Navigate") {
    let rc = NavigateController(); rc.isActive = true
    return PopupView(
        sessions: Session.qaShowcase, recentProjects: RecentProject.mockRecents,
        updater: DisabledUpdater(), pluginManager: previewPluginManager(), navigate: rc
    ).frame(width: 320)
}
