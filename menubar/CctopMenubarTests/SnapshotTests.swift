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

    func testGenerateRecentProjectsScreenshot() throws {
        let view = PopupView(
            sessions: Session.qaShowcase, recentProjects: RecentProject.mockRecents,
            updater: DisabledUpdater(), initialTab: .recent
        )
        try renderScreenshot(view: view, colorScheme: .dark, filename: "menubar-recent.png")
    }

    private func renderScreenshot(view: some View, colorScheme: ColorScheme, filename: String) throws {
        let docsDir = ProcessInfo.processInfo.environment["SRCROOT"]
            .map { $0 + "/../docs" } ?? "/tmp"
        let outputPath = "\(docsDir)/\(filename)"

        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        let styled = view
            .frame(width: 320)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .environment(\.colorScheme, colorScheme)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
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
