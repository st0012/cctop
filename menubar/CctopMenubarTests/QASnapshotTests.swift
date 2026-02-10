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

    // MARK: - Dark mode

    func testFiveSessionsDark() throws {
        try renderSnapshot(sessions: Session.qaFiveSessions, name: "10-five-sessions-dark", colorScheme: .dark)
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
        PopupView(sessions: sessions)
            .frame(width: 320)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .environment(\.colorScheme, .light)
    }

    // MARK: - Rendering

    private func renderSnapshot(
        sessions: [Session],
        name: String,
        colorScheme: ColorScheme = .light
    ) throws {
        let view = PopupView(sessions: sessions)
            .frame(width: 320)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
