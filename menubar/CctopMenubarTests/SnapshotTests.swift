import AppKit
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

/// Inert manager: no home-dir IO, every flag starts deterministically
/// false, so screenshots are reproducible across machines.
@MainActor
func inertPluginManager() -> PluginManager {
    PluginManager(homeDirectory: URL(fileURLWithPath: "/nonexistent"), refreshOnInit: false)
}

/// Shared snapshot render pipeline: hosts the view in a borderless window,
/// sizes it to fit, and writes a PNG into the named snapshot output directory.
@MainActor
@discardableResult
func renderPanelScreenshot(
    view: some View, colorScheme: ColorScheme, directoryName: String, filename: String, width: CGFloat = 320
) throws -> NSSize {
    let docsDir = snapshotOutputDirectory(named: directoryName)
    let outputPath = "\(docsDir)/\(filename)"
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: docsDir), withIntermediateDirectories: true
    )

    let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
    let styled = view
        .frame(width: width)
        .background {
            PanelSurfaceBackground()
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

func worstCaseReviewCleanupCandidate(now: Date = Date()) -> WorktreeCleanupCandidate {
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
        lastActiveAt: now.addingTimeInterval(-86_400 * 16),
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

func repoRoot() throws -> URL {
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

@MainActor
final class SnapshotTests: XCTestCase {
    /// Renders the PopupView with showcase sessions and saves light + dark screenshots.
    ///
    /// Run with:
    ///   make snapshots
    func testGenerateMenubarScreenshot() throws {
        let view = PopupView(
            sessions: SessionData.qaShowcase,
            userSessions: userSessionProjection(from: SessionData.qaShowcase),
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager()
        )
        try renderScreenshot(view: view, colorScheme: .light, filename: "menubar-light.png")
        try renderScreenshot(view: view, colorScheme: .dark, filename: "menubar-dark.png")
    }

    func testGenerateNavigateScreenshot() throws {
        let rc = NavigateController()
        rc.isActive = true
        let view = PopupView(
            sessions: Array(SessionData.qaShowcase.prefix(4)),
            userSessions: userSessionProjection(from: Array(SessionData.qaShowcase.prefix(4))),
            updater: DisabledUpdater(),
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
    ///   make snapshots
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

    func testGenerateRecentProjectsScreenshot() throws {
        let view = PopupView(
            sessions: SessionData.qaShowcase,
            userSessions: userSessionProjection(from: SessionData.qaShowcase),
            recentProjects: RecentProject.mockRecents,
            updater: DisabledUpdater(), pluginManager: inertPluginManager(), initialTab: .recent
        )
        try renderScreenshot(view: view, colorScheme: .dark, filename: "menubar-recent.png")
    }

    func testGenerateRecentProjectsReworkProof() throws {
        let home = NSHomeDirectory()
        let now = Date()
        let durableEditorPath = "\(home)/projects/cctop"
        let durableTerminalPath = "\(home)/projects/irb"
        let durableFallbackPath = "\(home)/projects/rdoc"
        let missingPath = "\(home)/projects/missing-recent-proof"
        let projectContainerPath = "\(home)/projects"
        let cachePath = "\(home)/Library/Caches/cctop-recent-noise"

        let sessions = [
            recentProofSession(
                projectPath: "/", projectName: "root",
                branch: "main", source: SessionData.ccSource,
                terminal: TerminalInfo(program: "Terminal", bundleId: "com.apple.Terminal"),
                endedAt: now
            ),
            recentProofSession(
                projectPath: home, projectName: URL(fileURLWithPath: home).lastPathComponent,
                branch: "main", source: SessionData.ccSource,
                terminal: TerminalInfo(program: "ghostty", bundleId: "com.mitchellh.ghostty"),
                endedAt: now.addingTimeInterval(-30)
            ),
            recentProofSession(
                projectPath: projectContainerPath, projectName: "projects",
                branch: "main", source: SessionData.codexSource,
                terminal: TerminalInfo(program: "Cursor"),
                endedAt: now.addingTimeInterval(-60)
            ),
            recentProofSession(
                projectPath: "/tmp/cctop-noise", projectName: "cctop-noise",
                branch: "main", source: SessionData.codexSource,
                terminal: TerminalInfo(program: "Cursor"),
                endedAt: now.addingTimeInterval(-90)
            ),
            recentProofSession(
                projectPath: "/private/tmp/cctop-noise", projectName: "private-noise",
                branch: "main", source: SessionData.ccSource,
                terminal: TerminalInfo(program: "ghostty", bundleId: "com.mitchellh.ghostty"),
                endedAt: now.addingTimeInterval(-120)
            ),
            recentProofSession(
                projectPath: "/var/folders/zz/cctop-noise", projectName: "var-noise",
                branch: "main", source: SessionData.opencodeSource,
                terminal: TerminalInfo(program: "Terminal", bundleId: "com.apple.Terminal"),
                endedAt: now.addingTimeInterval(-150)
            ),
            recentProofSession(
                projectPath: cachePath, projectName: "cache-noise",
                branch: "main", source: SessionData.piSource,
                terminal: TerminalInfo(program: "Zed"),
                endedAt: now.addingTimeInterval(-180)
            ),
            recentProofSession(
                projectPath: missingPath, projectName: "missing-noise",
                branch: "main", source: SessionData.codexSource,
                terminal: TerminalInfo(program: "Code"),
                endedAt: now.addingTimeInterval(-210)
            ),
            recentProofSession(
                projectPath: durableEditorPath, projectName: "cctop",
                branch: "codex/recent-projects-open-project", source: SessionData.codexSource,
                terminal: TerminalInfo(program: "Cursor", bundleId: "com.todesktop.230313mzl4w4u92"),
                endedAt: now.addingTimeInterval(-240)
            ),
            recentProofSession(
                projectPath: durableEditorPath, projectName: "cctop",
                branch: "codex/recent-projects-open-project", source: SessionData.ccSource,
                terminal: TerminalInfo(program: "Cursor"),
                endedAt: now.addingTimeInterval(-300)
            ),
            recentProofSession(
                projectPath: durableTerminalPath, projectName: "irb",
                branch: "master", source: SessionData.ccSource,
                terminal: TerminalInfo(program: "ghostty", bundleId: "com.mitchellh.ghostty"),
                endedAt: now.addingTimeInterval(-360)
            ),
            recentProofSession(
                projectPath: durableFallbackPath, projectName: "rdoc",
                branch: "unknown", source: SessionData.codexSource,
                terminal: TerminalInfo(program: "Codex"),
                endedAt: now.addingTimeInterval(-420)
            ),
        ]

        let recentProjects = HistoryManager.buildRecentProjects(
            from: sessions,
            projectPathExists: {
                ["/", home, projectContainerPath, durableEditorPath, durableTerminalPath, durableFallbackPath, cachePath].contains($0)
            }
        )

        XCTAssertEqual(recentProjects.map(\.projectName), ["cctop", "irb", "rdoc"])
        XCTAssertEqual(recentProjects.count, 3)
        XCTAssertEqual(recentProjects[0].sessionCount, 2)
        XCTAssertEqual(recentProjects[0].editorIcon, "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(recentProjects[0].openActionLabel, "Open in Cursor")
        XCTAssertEqual(recentProjects[1].editorIcon, "terminal")
        XCTAssertEqual(recentProjects[1].openActionLabel, "Open in Ghostty")
        XCTAssertEqual(recentProjects[2].editorIcon, "folder")
        XCTAssertEqual(recentProjects[2].openActionLabel, "Open Project Folder")
        XCTAssertEqual(recentProjects[2].metadataEvidenceText, "Codex \u{00B7} 1 session")

        let view = PopupView(
            sessions: [],
            userSessions: [],
            recentProjects: recentProjects,
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            initialTab: .recent
        )
        try renderPanelScreenshot(
            view: view,
            colorScheme: .dark,
            directoryName: "cctop-recent-rework-proof",
            filename: "recent-projects-rework.png"
        )
    }

    func testGenerateRecentProjectsFilteredEmptyProof() throws {
        let home = NSHomeDirectory()
        let sessions = [
            recentProofSession(
                projectPath: "/tmp/cctop-noise", projectName: "tmp-noise",
                branch: "main", source: SessionData.codexSource,
                terminal: TerminalInfo(program: "Cursor"),
                endedAt: Date()
            ),
            recentProofSession(
                projectPath: "\(home)/Library/Caches/cctop-noise", projectName: "cache-noise",
                branch: "main", source: SessionData.ccSource,
                terminal: TerminalInfo(program: "Ghostty"),
                endedAt: Date().addingTimeInterval(-60)
            ),
            recentProofSession(
                projectPath: "\(home)/projects/missing-recent-proof", projectName: "missing-noise",
                branch: "main", source: SessionData.codexSource,
                terminal: TerminalInfo(program: "Code"),
                endedAt: Date().addingTimeInterval(-120)
            ),
        ]
        let recentProjects = HistoryManager.buildRecentProjects(from: sessions, projectPathExists: { _ in false })

        XCTAssertTrue(recentProjects.isEmpty)

        let view = PopupView(
            sessions: [],
            userSessions: [],
            recentProjects: recentProjects,
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            initialTab: .recent
        )
        try renderPanelScreenshot(
            view: view,
            colorScheme: .dark,
            directoryName: "cctop-recent-rework-proof",
            filename: "recent-projects-all-filtered.png"
        )
    }

    func testGenerateRecentDesktopResumePrototypeProof() throws {
        let home = NSHomeDirectory()
        let now = Date()
        let targets: [RecentResumeTarget] = [
            .project(RecentProject(
                projectPath: "\(home)/projects/irb",
                projectName: "irb",
                lastBranch: "master",
                lastSessionAt: now.addingTimeInterval(-480),
                sessionCount: 3,
                lastEditor: "Ghostty",
                lastAgent: "Claude Code",
                workspaceFile: nil
            )),
            .desktopThread(.init(
                sessionId: "9f4a3d84-6360-4fb3-8fa7-656d283babac",
                title: "Test case refactor",
                projectPath: "\(home)/projects/cctop",
                projectName: "cctop",
                lastActiveAt: now.addingTimeInterval(-900)
            )),
            .project(RecentProject(
                projectPath: "\(home)/projects/rdoc",
                projectName: "rdoc",
                lastBranch: "unknown",
                lastSessionAt: now.addingTimeInterval(-1_200),
                sessionCount: 1,
                lastEditor: "Codex",
                lastAgent: "Codex",
                workspaceFile: nil
            )),
            .project(RecentProject(
                projectPath: "\(home)/projects/memories",
                projectName: "memories",
                lastBranch: "main",
                lastSessionAt: now.addingTimeInterval(-1_800),
                sessionCount: 2,
                lastEditor: "Cursor",
                lastAgent: "Codex",
                workspaceFile: "\(home)/projects/memories/memories.code-workspace"
            )),
        ]

        XCTAssertEqual(targets.map(\.openActionLabel), [
            "Open in Ghostty",
            "Open Claude Desktop",
            "Open Project Folder",
            "Open in Cursor",
        ])
        XCTAssertFalse(targets.contains { $0.openActionLabel.contains("Thread") || ($0.inlineActionLabel?.contains("Thread") ?? false) })

        let view = PopupView(
            sessions: [],
            userSessions: [],
            recentResumeTargets: targets,
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            initialTab: .recent
        )
        let size = try renderPanelScreenshot(
            view: view,
            colorScheme: .dark,
            directoryName: "cctop-recent-desktop-resume-proof",
            filename: "recent-desktop-resume-prototype.png"
        )
        XCTAssertLessThanOrEqual(size.width, 320)
    }

    func testGenerateCleanupScreenshot() throws {
        let view = PopupView(
            sessions: SessionData.qaShowcase,
            userSessions: userSessionProjection(from: SessionData.qaShowcase),
            recentProjects: RecentProject.mockRecents,
            cleanupCandidates: WorktreeCleanupCandidate.mockCandidates.filter(\.state.isActionable),
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            initialTab: .cleanup
        )
        try renderScreenshot(view: view, colorScheme: .dark, filename: "menubar-cleanup.png")
    }

    func testGenerateCleanupDiscoverabilityScreenshots() throws {
        let candidates = WorktreeCleanupCandidate.mockCandidates.filter(\.state.isActionable)
        let directoryName = "cctop-cleanup-discoverability-proof-\(Int(Date().timeIntervalSince1970))"
        let normalView = PopupView(
            sessions: SessionData.qaShowcase,
            userSessions: userSessionProjection(from: SessionData.qaShowcase),
            recentProjects: RecentProject.mockRecents,
            cleanupCandidates: candidates,
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            initialTab: .cleanup
        )
        let scanningView = PopupView(
            sessions: SessionData.qaShowcase,
            userSessions: userSessionProjection(from: SessionData.qaShowcase),
            recentProjects: RecentProject.mockRecents,
            cleanupCandidates: candidates,
            cleanupIsScanning: true,
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            initialTab: .cleanup
        )
        let nudgedView = PopupView(
            sessions: SessionData.qaShowcase,
            userSessions: userSessionProjection(from: SessionData.qaShowcase),
            recentProjects: RecentProject.mockRecents,
            cleanupCandidates: candidates,
            cleanupHasUnseenCandidates: true,
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            initialTab: .active
        )

        let normalSize = try renderPanelScreenshot(
            view: normalView,
            colorScheme: .dark,
            directoryName: directoryName,
            filename: "cleanup-tab-normal.png"
        )
        let scanningSize = try renderPanelScreenshot(
            view: scanningView,
            colorScheme: .dark,
            directoryName: directoryName,
            filename: "cleanup-tab-scanning.png"
        )
        let nudgedSize = try renderPanelScreenshot(
            view: nudgedView,
            colorScheme: .dark,
            directoryName: directoryName,
            filename: "cleanup-tab-nudged.png"
        )

        XCTAssertLessThanOrEqual(normalSize.width, 320)
        XCTAssertLessThanOrEqual(scanningSize.width, 320)
        XCTAssertLessThanOrEqual(nudgedSize.width, 320)
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
            sessions: SessionData.qaShowcase,
            userSessions: userSessionProjection(from: SessionData.qaShowcase),
            recentProjects: RecentProject.mockRecents,
            cleanupCandidates: candidates,
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            initialTab: .cleanup,
            initialCleanupCandidate: clean
        )
        let reviewView = PopupView(
            sessions: SessionData.qaShowcase,
            userSessions: userSessionProjection(from: SessionData.qaShowcase),
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
    ///   make snapshots
    func testGenerateThemeScreenshots() throws {
        for theme in AppTheme.allCases {
            ThemeManager.shared.setTheme(theme)
            let view = PopupView(
                sessions: SessionData.qaShowcase,
                userSessions: userSessionProjection(from: SessionData.qaShowcase),
                updater: DisabledUpdater(),
                pluginManager: inertPluginManager()
            )
            try renderScreenshot(view: view, colorScheme: .dark, filename: "theme-\(theme.rawValue)-dark.png")
            try renderScreenshot(view: view, colorScheme: .light, filename: "theme-\(theme.rawValue)-light.png")
        }
        // Restore default
        ThemeManager.shared.setTheme(.claude)
    }

    @discardableResult
    private func renderScreenshot(
        view: some View, colorScheme: ColorScheme, filename: String, width: CGFloat = 320
    ) throws -> NSSize {
        try renderPanelScreenshot(
            view: view, colorScheme: colorScheme,
            directoryName: "cctop-screenshots", filename: filename, width: width
        )
    }

    private func recentProofSession(
        projectPath: String,
        projectName: String,
        branch: String,
        source: String?,
        terminal: TerminalInfo?,
        endedAt: Date
    ) -> SessionData {
        SessionData(
            sessionId: UUID().uuidString,
            projectPath: projectPath,
            projectName: projectName,
            branch: branch,
            status: .idle,
            lastPrompt: nil,
            lastActivity: endedAt,
            startedAt: endedAt.addingTimeInterval(-600),
            terminal: terminal,
            pid: nil,
            lastTool: nil,
            lastToolDetail: nil,
            notificationMessage: nil,
            source: source,
            endedAt: endedAt
        )
    }

}

final class SnapshotContractTests: XCTestCase {
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

    func testSessionRowsAvoidPerRowTimelineAndInfiniteAnimations() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let viewsDirectory = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("CctopMenubar/Views")
        let viewSources = try FileManager.default.contentsOfDirectory(
            at: viewsDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        let source = try viewSources
            .map { try String(contentsOf: $0) }
            .joined(separator: "\n")

        XCTAssertFalse(source.contains("TimelineView("))
        XCTAssertFalse(source.contains("repeatForever"))
        XCTAssertFalse(source.contains("BlinkingCaret("))
        XCTAssertFalse(viewSources.contains { $0.lastPathComponent == "BlinkingCaret.swift" })
    }
}
