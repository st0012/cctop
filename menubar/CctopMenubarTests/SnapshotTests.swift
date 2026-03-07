import XCTest
@testable import CctopMenubar
import SwiftUI

@MainActor
final class SnapshotTests: XCTestCase {
    /// Renders the PopupView with showcase sessions and saves light + dark screenshots.
    ///
    /// Run with:
    ///   xcodebuild test -project menubar/CctopMenubar.xcodeproj -scheme CctopMenubar \
    ///     -only-testing:CctopMenubarTests/SnapshotTests/testGenerateMenubarScreenshot \
    ///     -derivedDataPath menubar/build/ CODE_SIGN_IDENTITY="-"
    func testGenerateMenubarScreenshot() throws {
        let view = PopupView(sessions: Session.qaShowcase, updater: DisabledUpdater())
        try renderScreenshot(view: view, colorScheme: .light, filename: "menubar-light.png")
        try renderScreenshot(view: view, colorScheme: .dark, filename: "menubar-dark.png")
    }

    func testGenerateRefocusScreenshot() throws {
        let rc = RefocusController()
        rc.isActive = true
        let view = PopupView(
            sessions: Session.qaShowcase, updater: DisabledUpdater(), refocus: rc
        )
        try renderScreenshot(view: view, colorScheme: .dark, filename: "menubar-refocus.png")
    }

    func testGenerateCompactScreenshot() throws {
        let view = TranslucentPill {
            SmartBarView(sessions: Session.qaShowcase)
        }
        try renderScreenshot(view: view, colorScheme: .light, filename: "menubar-compact-light.png")
        try renderScreenshot(view: view, colorScheme: .dark, filename: "menubar-compact-dark.png")
    }

    func testGenerateRecentProjectsScreenshot() throws {
        let view = PopupView(
            sessions: Session.qaShowcase, recentProjects: RecentProject.mockRecents,
            updater: DisabledUpdater(), initialTab: .recent
        )
        try renderScreenshot(view: view, colorScheme: .dark, filename: "menubar-recent.png")
    }

    // MARK: - Compact Mode Mockups

    func testGenerateCompactMockups() throws {
        let showcase = Session.qaShowcase
        let allClear: [Session] = [
            .mock(status: .working, lastTool: "Edit"),
            .mock(status: .working, lastTool: "Bash"),
            .mock(status: .idle),
            .mock(status: .idle),
        ]
        let singleAlert: [Session] = [
            .mock(status: .waitingPermission),
            .mock(status: .working, lastTool: "Edit"),
            .mock(status: .working, lastTool: "Bash"),
        ]

        let bg = desktopGradient

        // Concept A: Dot Strip (narrow + translucent)
        let dotStripView = VStack(alignment: .leading, spacing: 16) {
            mockupLabel("CONCEPT A: DOT STRIP (28px, narrow)")
            mockupRow("All Clear") { TranslucentPill { DotStripView(sessions: allClear) } }
            mockupRow("Needs Attention") { TranslucentPill { DotStripView(sessions: showcase) } }
            mockupRow("Single Alert") { TranslucentPill { DotStripView(sessions: singleAlert) } }
        }
        .padding(20)
        .background(bg)

        try renderScreenshot(view: dotStripView, colorScheme: .dark, filename: "mockup-dotstrip-dark.png", width: 360)

        // Concept B: Smart Bar (narrow + translucent)
        let smartBarView = VStack(alignment: .leading, spacing: 16) {
            mockupLabel("CONCEPT B: SMART BAR (32px, narrow)")
            mockupRow("All Clear") { TranslucentPill { SmartBarView(sessions: allClear) } }
            mockupRow("Needs Attention") { TranslucentPill { SmartBarView(sessions: showcase) } }
            mockupRow("Single Alert") { TranslucentPill { SmartBarView(sessions: singleAlert) } }
        }
        .padding(20)
        .background(bg)

        try renderScreenshot(view: smartBarView, colorScheme: .dark, filename: "mockup-smartbar-dark.png", width: 360)

        // Side-by-side comparison
        let comparison = VStack(alignment: .leading, spacing: 16) {
            mockupLabel("CURRENT (44px, 320px wide)")
            TranslucentPill {
                HeaderView(sessions: showcase, isCompactMode: true)
            }
            .frame(width: 320)

            mockupLabel("CONCEPT A: DOT STRIP (28px, narrow)")
            TranslucentPill { DotStripView(sessions: showcase) }

            mockupLabel("CONCEPT B: SMART BAR (32px, narrow)")
            TranslucentPill { SmartBarView(sessions: showcase) }
        }
        .padding(20)
        .background(bg)

        try renderScreenshot(view: comparison, colorScheme: .dark, filename: "mockup-comparison-dark.png", width: 360)
    }

    private func mockupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.7))
    }

    private func mockupRow<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
            content()
        }
    }

    private var desktopGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.15, green: 0.12, blue: 0.25),
                Color(red: 0.1, green: 0.18, blue: 0.28),
                Color(red: 0.12, green: 0.15, blue: 0.22),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func renderScreenshot(
        view: some View, colorScheme: ColorScheme, filename: String, width: CGFloat = 320
    ) throws {
        let docsDir = ProcessInfo.processInfo.environment["SRCROOT"]
            .map { $0 + "/../docs" } ?? "/tmp"
        let outputPath = "\(docsDir)/\(filename)"

        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        let styled = view
            .frame(width: width)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .environment(\.colorScheme, colorScheme)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)

        let hostingView = NSHostingView(rootView: styled)
        window.contentView = hostingView

        let fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()

        let bitmapRep = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds),
            "Failed to create bitmap for \(filename)"
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

        let pngData = try XCTUnwrap(
            bitmapRep.representation(using: .png, properties: [:]),
            "Failed to generate PNG for \(filename)"
        )

        try pngData.write(to: URL(fileURLWithPath: outputPath))
        print("Screenshot saved to: \(outputPath)")
    }
}
