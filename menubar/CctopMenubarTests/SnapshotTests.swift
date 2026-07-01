import XCTest
@testable import CctopMenubar
import SwiftUI

func snapshotOutputDirectory(named directoryName: String) -> String {
    // Set CCTOP_SNAPSHOT_OUTPUT_DIR to intentionally refresh committed docs screenshots.
    ProcessInfo.processInfo.environment["CCTOP_SNAPSHOT_OUTPUT_DIR"] ??
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(directoryName)
            .path
}

@MainActor
final class SnapshotTests: XCTestCase {
    /// Renders the PopupView with showcase sessions and saves light + dark screenshots.
    ///
    /// Run with:
    ///   xcodebuild test -project menubar/CctopMenubar.xcodeproj -scheme CctopMenubar \
    ///     -only-testing:CctopMenubarTests/SnapshotTests/testGenerateMenubarScreenshot \
    ///     -derivedDataPath menubar/build/ CODE_SIGN_IDENTITY="-"
    func testGenerateMenubarScreenshot() throws {
        let view = PopupView(
            sessions: Session.qaShowcase, updater: DisabledUpdater(), pluginManager: inertPluginManager()
        )
        try renderScreenshot(view: view, colorScheme: .light, filename: "menubar-light.png")
        try renderScreenshot(view: view, colorScheme: .dark, filename: "menubar-dark.png")
    }

    func testGenerateNavigateScreenshot() throws {
        let rc = NavigateController()
        rc.isActive = true
        let view = PopupView(
            sessions: Session.qaShowcase, updater: DisabledUpdater(),
            pluginManager: inertPluginManager(), navigate: rc
        )
        try renderScreenshot(view: view, colorScheme: .dark, filename: "menubar-navigate.png")
    }

    /// Renders the EmptyStateView in its first-run "nothing installed yet" form
    /// — all four supported agents (Claude Code/Desktop, opencode, pi, Codex CLI/Desktop) detected
    /// on the machine with their respective install CTAs — for use in the README
    /// and marketing site. Shows the full breadth of agent support in one shot.
    ///
    /// Run with:
    ///   xcodebuild test -project menubar/CctopMenubar.xcodeproj -scheme CctopMenubar \
    ///     -only-testing:CctopMenubarTests/SnapshotTests/testGenerateEmptyStateScreenshot \
    ///     -derivedDataPath menubar/build/ CODE_SIGN_IDENTITY="-"
    func testGenerateEmptyStateScreenshot() throws {
        let pm = inertPluginManager()
        pm.ccInstalled = false
        pm.ocInstalled = false
        pm.ocConfigExists = true
        pm.ocNeedsUpdate = false
        pm.piInstalled = false
        pm.piConfigExists = true
        pm.codexInstalled = false
        pm.codexConfigExists = true
        pm.codexNeedsUpdate = false
        let view = EmptyStateView(pluginManager: pm)
        try renderScreenshot(view: view, colorScheme: .light, filename: "empty-state-light.png")
        try renderScreenshot(view: view, colorScheme: .dark, filename: "empty-state-dark.png")
    }

    func testGenerateOnboardingSettingsScreenshot() throws {
        let pm = inertPluginManager()
        pm.ccInstalled = false
        pm.ocInstalled = false
        pm.ocConfigExists = true
        pm.ocNeedsUpdate = false
        pm.piInstalled = false
        pm.piConfigExists = true
        pm.codexInstalled = false
        pm.codexConfigExists = true
        pm.codexNeedsUpdate = false

        let view = SettingsSection(updater: DisabledUpdater(), pluginManager: pm)
        try renderScreenshot(view: view, colorScheme: .light, filename: "onboarding-settings-light.png", width: 360)
        try renderScreenshot(view: view, colorScheme: .dark, filename: "onboarding-settings-dark.png", width: 360)
    }

    func testOnboardingCopyNamesDesktopHostsAndOmitsLegacyCodexFlag() throws {
        let repo = try repoRoot()
        let checkedFiles = [
            "menubar/CctopMenubar/Views/EmptyStateView.swift",
            "menubar/CctopMenubar/Views/SettingsSection.swift",
            "menubar/CctopMenubar/Views/CodexPluginRowView.swift",
            "README.md",
            "site/index.html",
            "plugins/codex/cctop-shim.sh",
        ]

        let combined = try checkedFiles.map { path in
            try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
        }.joined(separator: "\n")

        XCTAssertFalse(combined.contains("codex_hooks feature flag"))
        XCTAssertFalse(combined.contains("Enable experimental feature?"))
        XCTAssertFalse(combined.contains("will show a startup warning"))
        XCTAssertTrue(combined.contains("Claude Code / Desktop"))
        XCTAssertTrue(combined.contains("Codex CLI / Desktop"))
        XCTAssertTrue(combined.contains("Claude Desktop"))
        XCTAssertTrue(combined.contains("Codex Desktop"))
        XCTAssertTrue(combined.contains("Install Hooks"))
    }

    func testGenerateRecentProjectsScreenshot() throws {
        let view = PopupView(
            sessions: Session.qaShowcase, recentProjects: RecentProject.mockRecents,
            updater: DisabledUpdater(), pluginManager: inertPluginManager(), initialTab: .recent
        )
        try renderScreenshot(view: view, colorScheme: .dark, filename: "menubar-recent.png")
    }

    func testGenerateCleanupScreenshot() throws {
        let view = PopupView(
            sessions: Session.qaShowcase,
            recentProjects: RecentProject.mockRecents,
            cleanupCandidates: WorktreeCleanupCandidate.mockCandidates.filter(\.state.isActionable),
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            initialTab: .cleanup
        )
        try renderScreenshot(view: view, colorScheme: .dark, filename: "menubar-cleanup.png")
    }

    func testGenerateCleanupDetailScreenshots() throws {
        let clean = WorktreeCleanupCandidate.mock(
            path: "/Users/dev/projects/rdoc/.claude/worktrees/stupefied-panini-cface5",
            sessionName: "Check RDoc option parser edge cases",
            branch: "claude/stupefied-panini-cface5",
            storageBytes: 4 * 1_024 * 1_024
        )
        let review = worstCaseReviewCleanupCandidate()
        let candidates = [clean, review]

        let cleanView = PopupView(
            sessions: Session.qaShowcase,
            recentProjects: RecentProject.mockRecents,
            cleanupCandidates: candidates,
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            initialTab: .cleanup,
            initialCleanupCandidate: clean
        )
        let reviewView = PopupView(
            sessions: Session.qaShowcase,
            recentProjects: RecentProject.mockRecents,
            cleanupCandidates: candidates,
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            initialTab: .cleanup,
            initialCleanupCandidate: review
        )

        let cleanSize = try renderScreenshot(
            view: cleanView, colorScheme: .dark, filename: "menubar-cleanup-detail-clean.png"
        )
        let reviewSize = try renderScreenshot(
            view: reviewView, colorScheme: .dark, filename: "menubar-cleanup-detail-review.png"
        )

        XCTAssertLessThanOrEqual(cleanSize.width, 320)
        XCTAssertLessThanOrEqual(reviewSize.width, 320)
        XCTAssertLessThanOrEqual(cleanSize.height, 430)
        XCTAssertLessThanOrEqual(reviewSize.height, 430)
    }

    /// Generates theme showcase screenshots for all 4 themes in both dark and light modes.
    ///
    /// Run with:
    ///   xcodebuild test -project menubar/CctopMenubar.xcodeproj -scheme CctopMenubar \
    ///     -only-testing:CctopMenubarTests/SnapshotTests/testGenerateThemeScreenshots \
    ///     -derivedDataPath menubar/build/ CODE_SIGN_IDENTITY="-"
    func testGenerateThemeScreenshots() throws {
        for theme in AppTheme.allCases {
            ThemeManager.shared.setTheme(theme)
            let view = PopupView(
                sessions: Session.qaShowcase, updater: DisabledUpdater(), pluginManager: inertPluginManager()
            )
            try renderScreenshot(view: view, colorScheme: .dark, filename: "theme-\(theme.rawValue)-dark.png")
            try renderScreenshot(view: view, colorScheme: .light, filename: "theme-\(theme.rawValue)-light.png")
        }
        // Restore default
        ThemeManager.shared.setTheme(.claude)
    }

    /// Inert manager: no home-dir IO, every flag starts deterministically
    /// false, so screenshots are reproducible across machines.
    private func inertPluginManager() -> PluginManager {
        PluginManager(homeDirectory: URL(fileURLWithPath: "/nonexistent"), refreshOnInit: false)
    }

    @discardableResult
    private func renderScreenshot(
        view: some View, colorScheme: ColorScheme, filename: String, width: CGFloat = 320
    ) throws -> NSSize {
        let docsDir = snapshotOutputDirectory(named: "cctop-screenshots")
        let outputPath = "\(docsDir)/\(filename)"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: docsDir), withIntermediateDirectories: true
        )

        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        let styled = view
            .frame(width: width)
            .background {
                PanelSurfaceBackground(usesMaterial: false)
            }
            .overlay {
                PanelAccentHairline(cornerRadius: AppChrome.panelCornerRadius)
            }
            .clipShape(RoundedRectangle(cornerRadius: AppChrome.panelCornerRadius, style: .continuous))
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
        return fittingSize
    }

    private func worstCaseReviewCleanupCandidate() -> WorktreeCleanupCandidate {
        let path = "/Users/st0012/projects/cctop/.claude/worktrees/very-long-review-worktree-name-for-layout"
        let state = WorktreeCleanupCandidate.State.review([
            "Worktree has uncommitted tracked changes",
            WorktreeCleanupCandidate.untrackedFilesReason,
            "No upstream branch",
            "Worktree is locked",
        ])
        return WorktreeCleanupCandidate(
            id: path,
            sessionName: "Investigate cleanup tab layout with very long session naming",
            worktreePath: path,
            worktreeName: URL(fileURLWithPath: path).lastPathComponent,
            branchName: "claude/review-layout-with-long-branch-name-and-no-upstream",
            lastActiveAt: Date().addingTimeInterval(-86_400 * 16),
            storageBytes: 426 * 1_024 * 1_024,
            state: state,
            checks: [
                WorktreeCleanupCheck(label: "No active cctop sessions here", status: .ok),
                WorktreeCleanupCheck(label: "Path is a registered linked worktree", status: .ok),
                WorktreeCleanupCheck(label: "No uncommitted tracked changes", status: .review),
                WorktreeCleanupCheck(label: "No untracked files", status: .review),
                WorktreeCleanupCheck(label: "No ignored files", status: .ok),
                WorktreeCleanupCheck(label: "Branch has no unique local commits", status: .review),
                WorktreeCleanupCheck(label: "Main checkout path is known", status: .ok),
                WorktreeCleanupCheck(label: "Worktree is not locked", status: .ok),
                WorktreeCleanupCheck(label: "Storage size scan completed", status: .ok),
            ],
            reviewEvidence: WorktreeCleanupCandidate.mockReviewEvidence(for: state)
        )
    }

    private func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("menubar/CctopMenubar.xcodeproj")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw XCTSkip("Could not locate repository root")
    }
}
