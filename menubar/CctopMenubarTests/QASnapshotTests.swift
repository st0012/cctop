import XCTest
@testable import CctopMenubar
import SwiftUI

/// QA snapshot tests that render PopupView with various session configurations.
///
/// Each test saves a PNG to /tmp/cctop-qa/<scenario>.png for visual inspection.
/// Run all QA snapshots:
///   xcodebuild test -project menubar/CctopMenubar.xcodeproj -scheme CctopMenubar \
///     -only-testing:CctopMenubarTests/QASnapshotTests \
///     -derivedDataPath menubar/build/ CODE_SIGN_IDENTITY="-"
@MainActor
final class QASnapshotTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(
            atPath: "/tmp/cctop-qa",
            withIntermediateDirectories: true
        )
    }

    // MARK: - Session count scenarios

    func testEmpty() throws {
        try renderSnapshot(sessions: [], name: "01-empty")
    }

    func testSingleSession() throws {
        try renderSnapshot(sessions: Session.qaSingle, name: "02-single")
    }

    func testFourSessions() throws {
        try renderSnapshot(sessions: Session.mockSessions, name: "03-four-sessions")
    }

    func testFiveSessions() throws {
        try renderSnapshot(sessions: Session.qaFiveSessions, name: "04-five-sessions")
    }

    func testSixSessions() throws {
        try renderSnapshot(sessions: Session.qaSixSessions, name: "05-six-sessions")
    }

    func testEightSessions() throws {
        try renderSnapshot(sessions: Session.qaEightSessions, name: "06-eight-sessions")
    }

    // MARK: - Badge count scenarios

    func testAllAttention() throws {
        try renderSnapshot(sessions: Session.qaAllAttention, name: "07-all-attention")
    }

    func testAllIdle() throws {
        try renderSnapshot(sessions: Session.qaAllIdle, name: "08-all-idle")
    }

    // MARK: - Edge cases

    func testLongNames() throws {
        try renderSnapshot(sessions: Session.qaLongNames, name: "09-long-names")
    }

    func testLongSessionNames() throws {
        try renderSnapshot(sessions: Session.qaLongSessionNames, name: "09b-long-session-names")
    }

    func testDesktopProjectNames() throws {
        try renderSnapshot(sessions: Session.qaShowcase, name: "09c-desktop-project-names")
    }

    // MARK: - Dark mode

    func testFiveSessionsDark() throws {
        try renderSnapshot(sessions: Session.qaFiveSessions, name: "10-five-sessions-dark", colorScheme: .dark)
    }

    // MARK: - Update UI scenarios

    func testSettingsUpdateAvailable() throws {
        let updater = DisabledUpdater()
        updater.pendingUpdateVersion = "0.7.0"
        try renderSettingsSnapshot(updater: updater, name: "12-settings-update-available")
    }

    func testSettingsUpdateAvailableDark() throws {
        let updater = DisabledUpdater()
        updater.pendingUpdateVersion = "0.7.0"
        try renderSettingsSnapshot(updater: updater, name: "13-settings-update-available-dark", colorScheme: .dark)
    }

    func testSettingsUpToDate() throws {
        try renderSettingsSnapshot(updater: MockQAUpdater(), name: "14-settings-up-to-date")
    }

    func testSettingsDisabledDev() throws {
        try renderSettingsSnapshot(
            updater: DisabledUpdater(reason: .development),
            name: "15-settings-disabled-dev"
        )
    }

    // MARK: - Polish review matrix

    func testPolishReviewMatrix() throws {
        let schemes: [(ColorScheme, String)] = [(.light, "light"), (.dark, "dark")]
        for theme in AppTheme.allCases {
            ThemeManager.shared.setTheme(theme)
            for (colorScheme, schemeName) in schemes {
                try renderSnapshot(
                    sessions: Session.qaShowcase,
                    name: "20-active-\(theme.rawValue)-\(schemeName)",
                    colorScheme: colorScheme
                )
                try renderRecentSnapshot(
                    name: "21-recent-\(theme.rawValue)-\(schemeName)",
                    colorScheme: colorScheme
                )
                try renderSettingsSnapshot(
                    updater: DisabledUpdater(),
                    name: "22-settings-top-\(theme.rawValue)-\(schemeName)",
                    colorScheme: colorScheme
                )
                try renderSettingsSnapshot(
                    updater: DisabledUpdater(),
                    name: "23-settings-bottom-\(theme.rawValue)-\(schemeName)",
                    colorScheme: colorScheme,
                    scrollToBottom: true
                )
            }
        }
        ThemeManager.shared.setTheme(.claude)
    }

    // MARK: - Live update simulation

    /// Simulates adding a 5th session to an existing 4-session view.
    /// Captures before (4 sessions) and after (5 sessions) in the same hosting view
    /// to test that SwiftUI re-renders correctly when the data changes.
    func testAddFifthSession() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)

        let hostingView = NSHostingView(rootView: AnyView(popupView(for: Session.mockSessions)))
        window.contentView = hostingView

        // Render "before" with 4 sessions
        var fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        try captureToFile(hostingView: hostingView, path: "/tmp/cctop-qa/11-add-fifth-before.png")

        // Update to 5 sessions in the same hosting view
        hostingView.rootView = AnyView(popupView(for: Session.qaFiveSessions))
        fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        try captureToFile(hostingView: hostingView, path: "/tmp/cctop-qa/11-add-fifth-after.png")
    }

    private func popupView(for sessions: [Session]) -> some View {
        PopupView(sessions: sessions, updater: DisabledUpdater(), pluginManager: inertPluginManager())
            .frame(width: 320)
            .panelSnapshotChrome()
            .environment(\.colorScheme, .light)
    }

    /// Inert manager: no home-dir IO, every flag starts deterministically
    /// false, so snapshots never carry the developer's machine state.
    private func inertPluginManager() -> PluginManager {
        PluginManager(homeDirectory: URL(fileURLWithPath: "/nonexistent"), refreshOnInit: false)
    }

    // MARK: - Rendering

    private func renderSnapshot(
        sessions: [Session],
        name: String,
        colorScheme: ColorScheme = .light
    ) throws {
        let view = PopupView(sessions: sessions, updater: DisabledUpdater(), pluginManager: inertPluginManager())
            .frame(width: 320)
            .panelSnapshotChrome()
            .environment(\.colorScheme, colorScheme)

        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)

        let hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView

        let fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()

        try captureToFile(hostingView: hostingView, path: "/tmp/cctop-qa/\(name).png")
    }

    private func renderRecentSnapshot(
        name: String,
        colorScheme: ColorScheme = .light
    ) throws {
        let view = PopupView(
            sessions: Session.qaShowcase,
            recentProjects: RecentProject.mockRecents,
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            initialTab: .recent
        )
        .frame(width: 320)
        .panelSnapshotChrome()
        .environment(\.colorScheme, colorScheme)

        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)

        let hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView

        let fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()

        try captureToFile(hostingView: hostingView, path: "/tmp/cctop-qa/\(name).png")
    }

    private func renderSettingsSnapshot(
        updater: UpdaterBase,
        name: String,
        colorScheme: ColorScheme = .light,
        scrollToBottom: Bool = false
    ) throws {
        let view = SettingsSection(updater: updater, pluginManager: inertPluginManager())
            .frame(width: 320)
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            .environment(\.colorScheme, colorScheme)

        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)

        let hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView

        let fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        if scrollToBottom {
            scrollFirstScrollViewToBottom(in: hostingView)
            hostingView.layoutSubtreeIfNeeded()
        }

        try captureToFile(hostingView: hostingView, path: "/tmp/cctop-qa/\(name).png")
    }

    private func scrollFirstScrollViewToBottom(in view: NSView) {
        guard
            let scrollView = firstSubview(ofType: NSScrollView.self, in: view),
            let documentView = scrollView.documentView
        else { return }

        let maximumY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func firstSubview<T: NSView>(ofType type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(ofType: type, in: subview) { return match }
        }
        return nil
    }

    private func captureToFile(hostingView: NSHostingView<some View>, path: String) throws {
        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("Failed to create bitmap for \(path)")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            XCTFail("Failed to generate PNG for \(path)")
            return
        }

        try pngData.write(to: URL(fileURLWithPath: path))
        print("QA snapshot saved: \(path)")
    }
}

private extension View {
    func panelSnapshotChrome() -> some View {
        background {
            ZStack {
                Color.panelBackground
                Color.panelMaterialOverlay
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppChrome.panelCornerRadius, style: .continuous)
                .stroke(Color.panelControlBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppChrome.panelCornerRadius, style: .continuous))
    }
}

// MARK: - Mock Updater for QA

@MainActor
private class MockQAUpdater: UpdaterBase {
    override var canCheckForUpdates: Bool { true }
}
