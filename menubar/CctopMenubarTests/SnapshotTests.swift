import XCTest
@testable import CctopMenubar
import SwiftUI

final class SnapshotTests: XCTestCase {
    /// Renders the PopupView with mock sessions and saves a screenshot to docs/menubar.png.
    ///
    /// Run with:
    ///   xcodebuild test -project menubar/CctopMenubar.xcodeproj -scheme CctopMenubar \
    ///     -only-testing:CctopMenubarTests/SnapshotTests/testGenerateMenubarScreenshot \
    ///     -derivedDataPath menubar/build/ CODE_SIGN_IDENTITY="-"
    func testGenerateMenubarScreenshot() throws {
        let outputPath = ProcessInfo.processInfo.environment["SNAPSHOT_OUTPUT_PATH"]
            ?? (ProcessInfo.processInfo.environment["SRCROOT"].map { $0 + "/../docs/menubar.png" }
                ?? "/tmp/menubar.png")

        let view = PopupView(sessions: Session.mockSessions)
            .frame(width: 320)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .environment(\.colorScheme, .light)

        // Use an offscreen window so NSHostingView renders text correctly
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)

        let hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView

        // Let Auto Layout compute the fitting size
        let fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("Failed to create bitmap representation")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            XCTFail("Failed to generate PNG data")
            return
        }

        let url = URL(fileURLWithPath: outputPath)
        try pngData.write(to: url)
        print("Screenshot saved to: \(url.path)")
    }
}
