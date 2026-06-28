import XCTest
@testable import CctopMenubar
import SwiftUI

// swiftlint:disable file_length

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
        let environment = ProcessInfo.processInfo.environment
        let docsDir = environment["CCTOP_SNAPSHOT_OUTPUT_DIR"] ?? environment["SRCROOT"]
            .map { $0 + "/../docs" } ?? "/tmp"
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
            "Storage size scan completed after fallback sizing",
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
            suggestedCommand: nil,
            checks: [
                WorktreeCleanupCheck(label: "No active cctop sessions here", status: .ok),
                WorktreeCleanupCheck(label: "Path is a registered linked worktree", status: .ok),
                WorktreeCleanupCheck(label: "No uncommitted tracked changes", status: .review),
                WorktreeCleanupCheck(label: "No untracked files", status: .review),
                WorktreeCleanupCheck(label: "Branch has no unique local commits", status: .review),
                WorktreeCleanupCheck(label: "Main checkout path is known", status: .ok),
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

// swiftlint:disable type_body_length
@MainActor
final class WorktreeCleanupScenarioSnapshotTests: XCTestCase {
    private struct Scenario {
        let clean: WorktreeCleanupCandidate
        let review: WorktreeCleanupCandidate
        let untrackedOnly: WorktreeCleanupCandidate
        let secondaryReview: WorktreeCleanupCandidate
        let longStress: WorktreeCleanupCandidate
        let unknownSafety: WorktreeCleanupCandidate
        let ignoredCandidates: [WorktreeCleanupCandidate]

        var allCandidates: [WorktreeCleanupCandidate] {
            [clean, review, untrackedOnly, secondaryReview, longStress, unknownSafety]
        }

        var productInputCandidates: [WorktreeCleanupCandidate] {
            allCandidates + ignoredCandidates
        }
    }

    private struct CandidateSeed {
        let path: String
        let sessionName: String
        let branch: String
        let lastActiveAt: Date
        let storageBytes: Int64?
        let state: WorktreeCleanupCandidate.State
        let suggestedCommand: String?
        let checks: [WorktreeCleanupCheck]?
        let reviewEvidence: WorktreeCleanupReviewEvidence?

        init(
            path: String,
            sessionName: String,
            branch: String,
            lastActiveAt: Date,
            storageBytes: Int64?,
            state: WorktreeCleanupCandidate.State,
            suggestedCommand: String? = nil,
            checks: [WorktreeCleanupCheck]? = nil,
            reviewEvidence: WorktreeCleanupReviewEvidence? = nil
        ) {
            self.path = path
            self.sessionName = sessionName
            self.branch = branch
            self.lastActiveAt = lastActiveAt
            self.storageBytes = storageBytes
            self.state = state
            self.suggestedCommand = suggestedCommand
            self.checks = checks
            self.reviewEvidence = reviewEvidence
        }
    }

    private struct LocalDiagnostic {
        let historySessions: Int
        let sessionFiles: Int
        let uniquePaths: Int
        let worktreeStylePaths: Int
        let liveOverviewCandidates: Int
        let sourceSessions: Int
        let activePaths: Int
    }

    func testGenerateCleanupScenarioScreenshots() throws {
        let scenario = cleanupScenario()
        try renderLiveLocalOverview()
        try renderListScreenshots(for: scenario)
        try renderDetailScreenshots(for: scenario)
        try renderSpecialStateScreenshots(for: scenario)
    }

    private func renderListScreenshots(for scenario: Scenario) throws {
        let actionableCount = scenario.productInputCandidates.filter(\.state.isActionable).count
        XCTAssertEqual(actionableCount, scenario.allCandidates.count)
        XCTAssertGreaterThan(scenario.productInputCandidates.count, actionableCount)

        let mixedList = cleanupPopup(candidates: scenario.productInputCandidates)
        let mixedListSize = try renderScreenshot(
            view: mixedList, colorScheme: .dark, filename: "worktree-cleanup-list-mixed-dark.png"
        )
        try renderScreenshot(
            view: mixedList, colorScheme: .light, filename: "worktree-cleanup-list-mixed-light.png"
        )
        try renderScreenshot(
            view: mixedList, colorScheme: .dark, filename: "worktree-cleanup-ignored-suppression.png"
        )
        XCTAssertLessThanOrEqual(mixedListSize.width, 320)
        XCTAssertLessThanOrEqual(mixedListSize.height, 430)
    }

    private func renderDetailScreenshots(for scenario: Scenario) throws {
        let cleanSize = try renderScreenshot(
            view: cleanupPopup(candidates: scenario.productInputCandidates, selectedCandidate: scenario.clean),
            colorScheme: .dark,
            filename: "worktree-cleanup-detail-clean.png"
        )
        let reviewSize = try renderScreenshot(
            view: cleanupPopup(candidates: scenario.productInputCandidates, selectedCandidate: scenario.review),
            colorScheme: .dark,
            filename: "worktree-cleanup-detail-review.png"
        )
        let longSize = try renderScreenshot(
            view: cleanupPopup(candidates: scenario.productInputCandidates, selectedCandidate: scenario.longStress),
            colorScheme: .dark,
            filename: "worktree-cleanup-detail-long-stress.png"
        )
        let untrackedOnlySize = try renderScreenshot(
            view: cleanupPopup(candidates: scenario.productInputCandidates, selectedCandidate: scenario.untrackedOnly),
            colorScheme: .dark,
            filename: "worktree-cleanup-detail-untracked-only.png"
        )
        let unknownSize = try renderScreenshot(
            view: cleanupPopup(candidates: scenario.productInputCandidates, selectedCandidate: scenario.unknownSafety),
            colorScheme: .dark,
            filename: "worktree-cleanup-detail-unknown-safety.png"
        )

        XCTAssertLessThanOrEqual(cleanSize.width, 320)
        XCTAssertLessThanOrEqual(reviewSize.width, 320)
        XCTAssertLessThanOrEqual(longSize.width, 320)
        XCTAssertLessThanOrEqual(untrackedOnlySize.width, 320)
        XCTAssertLessThanOrEqual(unknownSize.width, 320)
        XCTAssertLessThanOrEqual(cleanSize.height, 430)
        XCTAssertLessThanOrEqual(reviewSize.height, 430)
        XCTAssertLessThanOrEqual(longSize.height, 430)
        XCTAssertLessThanOrEqual(untrackedOnlySize.height, 430)
        XCTAssertLessThanOrEqual(unknownSize.height, 430)
        XCTAssertEqual(scenario.unknownSafety.formattedStorage, "Unknown")
        XCTAssertNil(scenario.unknownSafety.suggestedCommand)
    }

    private func renderSpecialStateScreenshots(for scenario: Scenario) throws {
        let overflow = overflowCandidates()
        XCTAssertGreaterThanOrEqual(overflow.count, 8)

        let selectedRow = WorktreeCleanupTabView(
            candidates: overflow,
            selectedIndex: 1,
            selectedCandidate: Binding<WorktreeCleanupCandidate?>.constant(nil),
            onRemove: { _ in }
        )
        try renderScreenshot(
            view: selectedRow, colorScheme: .dark, filename: "worktree-cleanup-list-keyboard-selected.png"
        )

        let emptyState = WorktreeCleanupTabView(
            candidates: [],
            selectedIndex: nil,
            selectedCandidate: Binding<WorktreeCleanupCandidate?>.constant(nil),
            onRemove: { _ in }
        )
        try renderScreenshot(view: emptyState, colorScheme: .dark, filename: "worktree-cleanup-empty.png")

        let hiddenCleanupTab = cleanupPopup(candidates: scenario.ignoredCandidates)
        try renderScreenshot(
            view: hiddenCleanupTab, colorScheme: .dark, filename: "worktree-cleanup-no-actionable-popup.png"
        )
    }

    private func renderLiveLocalOverview() throws {
        let local = liveLocalDiagnostic()
        print(
            "Live cleanup diagnostic: history=\(local.historySessions), sessions=\(local.sessionFiles), "
            + "sources=\(local.sourceSessions), uniquePaths=\(local.uniquePaths), "
            + "worktreeStylePaths=\(local.worktreeStylePaths), activePaths=\(local.activePaths), "
            + "liveOverviewCandidates=\(local.liveOverviewCandidates)"
        )

        let candidates = liveLocalOverviewCandidates()
        guard !candidates.isEmpty else { return }
        let size = try renderScreenshot(
            view: cleanupPopup(candidates: candidates),
            colorScheme: .dark,
            filename: "worktree-cleanup-live-local-overview.png"
        )
        XCTAssertLessThanOrEqual(size.width, 320)
        XCTAssertLessThanOrEqual(size.height, 430)
    }

    @discardableResult
    private func renderScreenshot(
        view: some View, colorScheme: ColorScheme, filename: String, width: CGFloat = 320
    ) throws -> NSSize {
        let environment = ProcessInfo.processInfo.environment
        let docsDir = environment["CCTOP_SNAPSHOT_OUTPUT_DIR"] ?? environment["SRCROOT"]
            .map { $0 + "/../docs" } ?? "/tmp/cctop-worktree-cleanup-screenshots"
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

    private func cleanupPopup(
        candidates: [WorktreeCleanupCandidate],
        selectedCandidate: WorktreeCleanupCandidate? = nil,
        sessions: [Session] = Session.qaShowcase
    ) -> PopupView {
        PopupView(
            sessions: sessions,
            recentProjects: RecentProject.mockRecents,
            cleanupCandidates: candidates,
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            initialTab: .cleanup,
            initialCleanupCandidate: selectedCandidate
        )
    }

    private func cleanupScenario(now: Date = Date()) -> Scenario {
        let clean = cleanupScenarioCandidate(
            CandidateSeed(
                path: "/Users/st0012/projects/rdoc/.claude/worktrees/stupefied-panini-cface5",
                sessionName: "Check RDoc option parser edge cases",
                branch: "claude/stupefied-panini-cface5",
                lastActiveAt: now.addingTimeInterval(-86_400 * 22),
                storageBytes: 4 * 1_024 * 1_024,
                state: .clean
            )
        )
        let review = cleanupScenarioCandidate(
            CandidateSeed(
                path: "/Users/st0012/projects/cctop/.claude/worktrees/elegant-euler-73a179",
                sessionName: "Investigate cleanup tab layout",
                branch: "claude/elegant-euler-73a179",
                lastActiveAt: now.addingTimeInterval(-86_400 * 14),
                storageBytes: 426 * 1_024 * 1_024,
                state: .review([
                    "Worktree has uncommitted tracked changes",
                    WorktreeCleanupCandidate.untrackedFilesReason,
                    "No upstream branch",
                ])
            )
        )
        let untrackedOnly = cleanupScenarioCandidate(
            CandidateSeed(
                path: "/Users/st0012/projects/cctop/.claude/worktrees/untracked-local-notes",
                sessionName: "Review local notes before cleanup",
                branch: "claude/untracked-local-notes",
                lastActiveAt: now.addingTimeInterval(-86_400 * 17),
                storageBytes: 12 * 1_024 * 1_024,
                state: .review([WorktreeCleanupCandidate.untrackedFilesReason]),
                reviewEvidence: untrackedPreviewEvidence(paths: [
                    "foo.rb",
                    "bar.rb",
                    "something/",
                    "notes with spaces.md",
                    "tmp/cache.json",
                    "very-long-local-directory-name-for-middle-truncation/output.txt",
                ])
            )
        )
        let secondaryReview = cleanupScenarioCandidate(
            CandidateSeed(
                path: "/Users/st0012/projects/cctop/.claude/worktrees/strange-heisenberg-8777cd",
                sessionName: "Audit cleanup scanner worktree sources",
                branch: "claude/strange-heisenberg-8777cd",
                lastActiveAt: now.addingTimeInterval(-86_400 * 19),
                storageBytes: 16 * 1_024 * 1_024,
                state: .review([
                    "No upstream branch",
                    "Branch commit safety could not be verified",
                ])
            )
        )
        let unknownSafety = unknownSafetyCandidate(now: now)
        return Scenario(
            clean: clean,
            review: review,
            untrackedOnly: untrackedOnly,
            secondaryReview: secondaryReview,
            longStress: worstCaseReviewCleanupCandidate(now: now),
            unknownSafety: unknownSafety,
            ignoredCandidates: ignoredScenarioCandidates(now: now)
        )
    }

    private func cleanupScenarioCandidate(_ seed: CandidateSeed) -> WorktreeCleanupCandidate {
        WorktreeCleanupCandidate(
            id: seed.path,
            sessionName: seed.sessionName,
            worktreePath: seed.path,
            worktreeName: URL(fileURLWithPath: seed.path).lastPathComponent,
            branchName: seed.branch,
            lastActiveAt: seed.lastActiveAt,
            storageBytes: seed.storageBytes,
            state: seed.state,
            suggestedCommand: seed.suggestedCommand ?? cleanSuggestedCommand(for: seed),
            checks: seed.checks ?? cleanupScenarioChecks(for: seed.state, storageBytes: seed.storageBytes),
            reviewEvidence: seed.reviewEvidence ?? WorktreeCleanupCandidate.mockReviewEvidence(for: seed.state)
        )
    }

    private func cleanSuggestedCommand(for seed: CandidateSeed) -> String? {
        seed.state.isClean ? "git -C /Users/st0012/projects/rdoc worktree remove \(seed.path)" : nil
    }

    private func worstCaseReviewCleanupCandidate(now: Date) -> WorktreeCleanupCandidate {
        let path = "/Users/st0012/projects/cctop/.claude/worktrees/very-long-review-worktree-name-for-layout"
        let state = WorktreeCleanupCandidate.State.review([
            "Worktree has uncommitted tracked changes",
            WorktreeCleanupCandidate.untrackedFilesReason,
            "No upstream branch",
            "Storage size scan completed after fallback sizing",
        ])
        return WorktreeCleanupCandidate(
            id: path,
            sessionName: "Investigate cleanup tab layout with very long session naming",
            worktreePath: path,
            worktreeName: URL(fileURLWithPath: path).lastPathComponent,
            branchName: "claude/review-layout-with-long-branch-name-and-no-upstream",
            lastActiveAt: now.addingTimeInterval(-86_400 * 16),
            storageBytes: 426 * 1_024 * 1_024,
            state: state,
            suggestedCommand: nil,
            checks: [
                WorktreeCleanupCheck(label: "No active cctop sessions here", status: .ok),
                WorktreeCleanupCheck(label: "Path is a registered linked worktree", status: .ok),
                WorktreeCleanupCheck(label: "No uncommitted tracked changes", status: .review),
                WorktreeCleanupCheck(label: "No untracked files", status: .review),
                WorktreeCleanupCheck(label: "Branch has no unique local commits", status: .review),
                WorktreeCleanupCheck(label: "Main checkout path is known", status: .ok),
                WorktreeCleanupCheck(label: "Storage size scan completed", status: .ok),
            ],
            reviewEvidence: WorktreeCleanupCandidate.mockReviewEvidence(for: state)
        )
    }

    private func unknownSafetyCandidate(now: Date) -> WorktreeCleanupCandidate {
        cleanupScenarioCandidate(
            CandidateSeed(
                path: "/Users/st0012/projects/codex/.codex/worktrees/detached-unknown-safety",
                sessionName: "Inspect detached worktree with unknown cleanup safety",
                branch: "detached@unknown",
                lastActiveAt: now.addingTimeInterval(-86_400 * 31),
                storageBytes: nil,
                state: .review([
                    "Branch is unknown or detached",
                    "Git status could not be read",
                    "Main checkout path could not be verified",
                    "Branch upstream or commit safety could not be verified",
                    "Storage size scan failed",
                ]),
                checks: [
                    WorktreeCleanupCheck(label: "No active cctop sessions here", status: .ok),
                    WorktreeCleanupCheck(label: "Path is a registered linked worktree", status: .ok),
                    WorktreeCleanupCheck(label: "No uncommitted tracked changes", status: .review),
                    WorktreeCleanupCheck(label: "No untracked files", status: .review),
                    WorktreeCleanupCheck(label: "Branch has no unique local commits", status: .review),
                    WorktreeCleanupCheck(label: "Main checkout path is known", status: .review),
                    WorktreeCleanupCheck(label: "Storage size scan completed", status: .review),
                ]
            )
        )
    }

    private func ignoredScenarioCandidates(now: Date) -> [WorktreeCleanupCandidate] {
        [
            ignoredCandidate(
                path: "/Users/st0012/projects/cctop",
                sessionName: "Main checkout should stay quiet",
                branch: "master",
                lastActiveAt: now.addingTimeInterval(-3_600),
                reason: "Path is the main checkout, not a linked worktree"
            ),
            ignoredCandidate(
                path: "/Users/st0012/projects/cctop/.claude/worktrees/heuristic-newton-a46d2f",
                sessionName: "Active path stays protected",
                branch: "claude/heuristic-newton-a46d2f",
                lastActiveAt: now.addingTimeInterval(-900),
                reason: "Active cctop session is using this path"
            ),
            ignoredCandidate(
                path: "/Users/st0012/projects/cctop/.claude/worktrees/missing-local-dir",
                sessionName: "Missing local worktree",
                branch: "claude/missing-local-dir",
                lastActiveAt: now.addingTimeInterval(-86_400 * 40),
                reason: "Path no longer exists"
            ),
        ]
    }

    private func ignoredCandidate(
        path: String,
        sessionName: String,
        branch: String,
        lastActiveAt: Date,
        reason: String
    ) -> WorktreeCleanupCandidate {
        WorktreeCleanupCandidate(
            id: path,
            sessionName: sessionName,
            worktreePath: path,
            worktreeName: URL(fileURLWithPath: path).lastPathComponent,
            branchName: branch,
            lastActiveAt: lastActiveAt,
            storageBytes: nil,
            state: .ignored([reason]),
            suggestedCommand: nil,
            checks: [WorktreeCleanupCheck(label: reason, status: .ignored)]
        )
    }

    private func overflowCandidates(now: Date = Date()) -> [WorktreeCleanupCandidate] {
        let names = [
            "elegant-euler-73a179",
            "heuristic-newton-a46d2f",
            "optimistic-mestorf-1d360b",
            "strange-heisenberg-8777cd",
            "zen-ptolemy-b9795a",
            "tender-babbage-2ad835",
            "magical-herschel-4b3381",
            "stupefied-panini-cface5",
            "unruffled-yalow-3fad0c",
        ]
        return names.enumerated().map { index, name in
            cleanupScenarioCandidate(
                CandidateSeed(
                    path: "/Users/st0012/projects/cctop/.claude/worktrees/\(name)",
                    sessionName: "Review cleanup candidate with intentionally long row label \(index + 1)",
                    branch: "claude/\(name)-with-extra-long-branch-name",
                    lastActiveAt: now.addingTimeInterval(TimeInterval(-86_400 * (index + 3))),
                    storageBytes: Int64(index + 1) * 1_073_741_824,
                    state: index == 0 ? .clean : .review([WorktreeCleanupCandidate.untrackedFilesReason])
                )
            )
        }
    }

    private func liveLocalDiagnostic(now: Date = Date()) -> LocalDiagnostic {
        let historySessions = decodedLocalSessions(in: URL(fileURLWithPath: Config.historyDir()))
        let sessionFiles = decodedLocalSessions(in: URL(fileURLWithPath: Config.sessionsDir()))
        let sourceSessions = historySessions + sessionFiles
        let uniquePaths = Set(sourceSessions.map { WorktreeCleanupScanner.standardizedPath($0.projectPath) })
        let activeProjectPaths = Set(
            sessionFiles
                .filter { $0.endedAt == nil && now.timeIntervalSince($0.lastActivity) < 600 }
                .map { WorktreeCleanupScanner.standardizedPath($0.projectPath) }
        )
        return LocalDiagnostic(
            historySessions: historySessions.count,
            sessionFiles: sessionFiles.count,
            uniquePaths: uniquePaths.count,
            worktreeStylePaths: uniquePaths.filter { Self.isWorktreeStylePath($0) }.count,
            liveOverviewCandidates: liveLocalOverviewCandidates(now: now).count,
            sourceSessions: sourceSessions.count,
            activePaths: activeProjectPaths.count
        )
    }

    private func liveLocalOverviewCandidates(now: Date = Date()) -> [WorktreeCleanupCandidate] {
        let historySessions = decodedLocalSessions(in: URL(fileURLWithPath: Config.historyDir()))
        let sessionFiles = decodedLocalSessions(in: URL(fileURLWithPath: Config.sessionsDir()))
        let activeProjectPaths = Set(
            sessionFiles
                .filter { $0.endedAt == nil && now.timeIntervalSince($0.lastActivity) < 600 }
                .map { WorktreeCleanupScanner.standardizedPath($0.projectPath) }
        )
        var latestByPath: [String: Session] = [:]
        for session in historySessions + sessionFiles {
            let path = WorktreeCleanupScanner.standardizedPath(session.projectPath)
            guard Self.isWorktreeStylePath(path), !activeProjectPaths.contains(path) else { continue }
            if let existing = latestByPath[path], existing.effectiveEndDate >= session.effectiveEndDate { continue }
            latestByPath[path] = session
        }
        return latestByPath.values
            .sorted { $0.effectiveEndDate > $1.effectiveEndDate }
            .prefix(8)
            .map(liveOverviewCandidate(from:))
    }

    private func liveOverviewCandidate(from session: Session) -> WorktreeCleanupCandidate {
        let path = WorktreeCleanupScanner.standardizedPath(session.projectPath)
        return WorktreeCleanupCandidate(
            id: path,
            sessionName: session.displayName,
            worktreePath: path,
            worktreeName: URL(fileURLWithPath: path).lastPathComponent,
            branchName: session.branch.isEmpty ? "unknown" : session.branch,
            lastActiveAt: session.effectiveEndDate,
            storageBytes: nil,
            state: .review([
                "Bounded live screenshot skipped Git safety checks",
                "Storage size scan skipped",
            ]),
            suggestedCommand: nil,
            checks: [
                WorktreeCleanupCheck(label: "Real local session/path metadata", status: .ok),
                WorktreeCleanupCheck(label: "Git safety checks skipped for bounded screenshot", status: .review),
                WorktreeCleanupCheck(label: "Storage size scan skipped", status: .review),
            ]
        )
    }

    private static func isWorktreeStylePath(_ path: String) -> Bool {
        path.contains("/.claude/worktrees/") || path.contains("/.codex/worktrees/")
    }

    private func decodedLocalSessions(in directory: URL) -> [Session] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".tmp") }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder.sessionDecoder.decode(Session.self, from: data)
            }
    }

    private func cleanupScenarioChecks(
        for state: WorktreeCleanupCandidate.State,
        storageBytes: Int64?
    ) -> [WorktreeCleanupCheck] {
        let needsReview = !state.reasons.isEmpty
        return [
            WorktreeCleanupCheck(label: "No active cctop sessions here", status: .ok),
            WorktreeCleanupCheck(label: "Path is a registered linked worktree", status: .ok),
            WorktreeCleanupCheck(label: "No uncommitted tracked changes", status: needsReview ? .review : .ok),
            WorktreeCleanupCheck(label: "No untracked files", status: needsReview ? .review : .ok),
            WorktreeCleanupCheck(label: "Branch has no unique local commits", status: needsReview ? .review : .ok),
            WorktreeCleanupCheck(label: "Storage size scan completed", status: storageBytes == nil ? .review : .ok),
        ]
    }

    private func untrackedPreviewEvidence(paths: [String]) -> WorktreeCleanupReviewEvidence {
        guard let preview = WorktreeCleanupUntrackedPreview(paths: paths) else {
            return .empty
        }
        return WorktreeCleanupReviewEvidence(untrackedPreview: preview)
    }

    private func inertPluginManager() -> PluginManager {
        PluginManager(homeDirectory: URL(fileURLWithPath: "/nonexistent"), refreshOnInit: false)
    }
}
// swiftlint:enable type_body_length
// swiftlint:enable file_length
