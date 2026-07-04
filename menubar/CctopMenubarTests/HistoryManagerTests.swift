import Combine
import XCTest
@testable import CctopMenubar

@MainActor
final class HistoryManagerTests: XCTestCase {
    private var historyDir: URL!
    private var sut: HistoryManager!

    override func setUp() {
        super.setUp()
        historyDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cctop-history-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: historyDir, withIntermediateDirectories: true
        )
        sut = HistoryManager(historyDir: historyDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: historyDir)
        sut = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func mockSession(
        project: String,
        projectPath: String? = nil,
        endedAt: Date? = nil,
        lastActivity: Date = Date(),
        terminal: TerminalInfo? = TerminalInfo(program: "Code"),
        source: String? = nil
    ) -> Session {
        Session(
            sessionId: UUID().uuidString,
            projectPath: projectPath ?? "/Users/test/\(project)",
            projectName: project,
            branch: "main",
            status: .idle,
            lastPrompt: nil,
            lastActivity: lastActivity,
            startedAt: lastActivity,
            terminal: terminal,
            pid: nil,
            lastTool: nil,
            lastToolDetail: nil,
            notificationMessage: nil,
            source: source,
            endedAt: endedAt
        )
    }

    private func mockEntry(
        project: String,
        endedAt: Date? = nil,
        lastActivity: Date = Date()
    ) -> (url: URL, session: Session) {
        let session = mockSession(
            project: project, endedAt: endedAt, lastActivity: lastActivity
        )
        let url = historyDir.appendingPathComponent("\(UUID().uuidString).json")
        return (url, session)
    }

    private func recentProjects(
        from sessions: [Session],
        excludingActive activePaths: Set<String> = [],
        existingPaths: Set<String>? = nil
    ) -> [RecentProject] {
        HistoryManager.buildRecentProjects(
            from: sessions,
            excludingActive: activePaths,
            projectPathExists: { existingPaths?.contains($0) ?? true }
        )
    }

    // MARK: - filesToPrune tests

    func testFilesToPruneEmptyInput() {
        let result = sut.filesToPrune(from: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testFilesToPruneKeepsOnlyMostRecentPerProject() {
        let now = Date()
        let entries = [
            mockEntry(project: "app", endedAt: now),
            mockEntry(project: "app", endedAt: now.addingTimeInterval(-3600)),
            mockEntry(project: "app", endedAt: now.addingTimeInterval(-7200)),
        ]
        let result = sut.filesToPrune(from: entries)
        XCTAssertEqual(result.count, 2, "Should prune 2 older duplicates")
        XCTAssertTrue(result.contains(entries[1].url))
        XCTAssertTrue(result.contains(entries[2].url))
        XCTAssertFalse(result.contains(entries[0].url))
    }

    func testFilesToPruneRemovesOldEntries() {
        let old = Date().addingTimeInterval(TimeInterval(-31 * 86400))
        let recent = Date().addingTimeInterval(-3600)
        let entries = [
            mockEntry(project: "recent-proj", endedAt: recent),
            mockEntry(project: "old-proj", endedAt: old),
        ]
        let result = sut.filesToPrune(from: entries)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.contains(entries[1].url))
    }

    func testFilesToPruneKeepsRecentEntries() {
        let recent = Date().addingTimeInterval(-86400) // 1 day ago
        let entries = [mockEntry(project: "proj", endedAt: recent)]
        let result = sut.filesToPrune(from: entries)
        XCTAssertTrue(result.isEmpty)
    }

    func testFilesToPruneEnforcesMaxFiles() {
        let now = Date()
        var entries: [(url: URL, session: Session)] = []
        for i in 0..<55 {
            entries.append(mockEntry(
                project: "proj-\(i)",
                endedAt: now.addingTimeInterval(TimeInterval(-i * 3600))
            ))
        }
        let result = sut.filesToPrune(from: entries)
        XCTAssertEqual(result.count, 5, "Should prune 5 excess entries beyond maxFiles=50")
    }

    func testFilesToPruneCombinedRules() {
        let now = Date()
        let entries = [
            // Most recent for proj-a (keep)
            mockEntry(project: "proj-a", endedAt: now),
            // Duplicate for proj-a (prune: dedup)
            mockEntry(project: "proj-a", endedAt: now.addingTimeInterval(-3600)),
            // Old entry for proj-b (prune: age)
            mockEntry(project: "proj-b", endedAt: now.addingTimeInterval(TimeInterval(-35 * 86400))),
            // Recent entry for proj-c (keep)
            mockEntry(project: "proj-c", endedAt: now.addingTimeInterval(-7200)),
        ]
        let result = sut.filesToPrune(from: entries)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains(entries[1].url), "Duplicate should be pruned")
        XCTAssertTrue(result.contains(entries[2].url), "Old entry should be pruned")
    }

    // MARK: - buildRecentProjects tests

    func testBuildRecentProjectsGroupsByPath() {
        let now = Date()
        let sessions = [
            mockSession(project: "app", endedAt: now),
            mockSession(project: "app", endedAt: now.addingTimeInterval(-3600)),
            mockSession(project: "app", endedAt: now.addingTimeInterval(-7200)),
        ]
        let result = recentProjects(from: sessions)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].sessionCount, 3)
        XCTAssertEqual(result[0].projectName, "app")
    }

    func testBuildRecentProjectsExcludesActive() {
        let now = Date()
        let sessions = [
            mockSession(project: "active", endedAt: now),
            mockSession(project: "inactive", endedAt: now),
        ]
        let result = recentProjects(
            from: sessions,
            excludingActive: ["/Users/test/active"]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].projectName, "inactive")
    }

    func testBuildRecentProjectsSortsByRecent() {
        let now = Date()
        let sessions = [
            mockSession(project: "old", endedAt: now.addingTimeInterval(-7200)),
            mockSession(project: "new", endedAt: now),
            mockSession(project: "mid", endedAt: now.addingTimeInterval(-3600)),
        ]
        let result = recentProjects(from: sessions)
        XCTAssertEqual(result.map(\.projectName), ["new", "mid", "old"])
    }

    func testBuildRecentProjectsCapsAtTen() {
        let now = Date()
        var sessions: [Session] = []
        for i in 0..<15 {
            sessions.append(mockSession(
                project: "proj-\(i)",
                endedAt: now.addingTimeInterval(TimeInterval(-i * 3600))
            ))
        }
        let result = recentProjects(from: sessions)
        XCTAssertEqual(result.count, 10)
    }

    func testBuildRecentProjectsUsesEndedAt() {
        let now = Date()
        let session = mockSession(
            project: "app",
            endedAt: now.addingTimeInterval(-60),
            lastActivity: now.addingTimeInterval(-7200)
        )
        let result = recentProjects(from: [session])
        XCTAssertEqual(result.count, 1)
        // lastSessionAt should use endedAt (60s ago), not lastActivity (2h ago)
        let elapsed = Int(-result[0].lastSessionAt.timeIntervalSinceNow)
        XCTAssertTrue(elapsed < 120, "Should use endedAt, not lastActivity")
    }

    func testBuildRecentProjectsExcludesDesktopAppSessions() {
        let desktopApps = [
            (bundleId: "com.anthropic.claudefordesktop", project: "claude-thing"),
            (bundleId: "com.openai.codex", project: "codex-thing"),
        ]
        for app in desktopApps {
            let terminal = TerminalInfo(
                program: "", sessionId: nil, tty: nil, bundleId: app.bundleId
            )
            let sessions = [
                mockSession(project: app.project, endedAt: Date(), terminal: terminal),
                mockSession(project: "vscode-thing", endedAt: Date()),
            ]
            let result = recentProjects(from: sessions)
            XCTAssertEqual(result.map(\.projectName), ["vscode-thing"], "for \(app.bundleId)")
        }
    }

    func testRecentProjectDurabilityRejectsMissingPath() {
        XCTAssertFalse(
            HistoryManager.isDurableRecentProjectPath(
                "/Users/test/missing-project",
                projectPathExists: { _ in false }
            )
        )
    }

    func testRecentProjectDurabilityRejectsTemporaryAndCachePaths() {
        let tempPaths = [
            "/tmp/cctop-noise",
            "/private/tmp/cctop-noise",
            NSTemporaryDirectory() + "cctop-noise",
            "/var/folders/zz/cctop-noise",
            NSHomeDirectory() + "/Library/Caches/cctop-noise",
            NSHomeDirectory() + "/.cache/cctop-noise",
        ]

        for path in tempPaths {
            XCTAssertFalse(
                HistoryManager.isDurableRecentProjectPath(path, projectPathExists: { _ in true }),
                path
            )
        }
    }

    func testRecentProjectDurabilityRejectsObviousNonProjectRoots() {
        let nonProjectRoots = [
            "/",
            NSHomeDirectory(),
            NSHomeDirectory() + "/projects",
        ]

        for path in nonProjectRoots {
            XCTAssertFalse(
                HistoryManager.isDurableRecentProjectPath(path, projectPathExists: { _ in true }),
                path
            )
        }
    }

    func testRecentProjectDurabilityKeepsExistingDurablePath() {
        XCTAssertTrue(
            HistoryManager.isDurableRecentProjectPath(
                "/Users/test/projects/rdoc",
                projectPathExists: { _ in true }
            )
        )
    }

    func testRecentProjectDurabilityKeepsChildProjectPaths() {
        let childProjects = [
            NSHomeDirectory() + "/projects/rdoc",
            NSHomeDirectory() + "/work/client-app",
        ]

        for path in childProjects {
            XCTAssertTrue(
                HistoryManager.isDurableRecentProjectPath(path, projectPathExists: { _ in true }),
                path
            )
        }
    }

    func testBuildRecentProjectsFiltersNonDurablePathsBeforeRankingAndCounting() {
        let now = Date()
        let realPath = "/Users/test/projects/rdoc"
        let sessions = [
            mockSession(
                project: "tmp-newest",
                projectPath: "/tmp/cctop-noise",
                endedAt: now
            ),
            mockSession(
                project: "missing-newer",
                projectPath: "/Users/test/projects/missing",
                endedAt: now.addingTimeInterval(-60)
            ),
            mockSession(
                project: "cache-newer",
                projectPath: NSHomeDirectory() + "/Library/Caches/cctop-noise",
                endedAt: now.addingTimeInterval(-120)
            ),
            mockSession(
                project: "rdoc",
                projectPath: realPath,
                endedAt: now.addingTimeInterval(-180)
            ),
            mockSession(
                project: "rdoc",
                projectPath: realPath,
                endedAt: now.addingTimeInterval(-240)
            ),
        ]

        let result = recentProjects(
            from: sessions,
            existingPaths: [
                "/tmp/cctop-noise",
                NSHomeDirectory() + "/Library/Caches/cctop-noise",
                realPath,
            ]
        )

        XCTAssertEqual(result.map(\.projectName), ["rdoc"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].sessionCount, 2)
    }

    func testBuildRecentProjectsGroupsByCanonicalProjectPath() {
        let now = Date()
        let canonicalPath = "/Users/test/projects/rdoc"
        let sessions = [
            mockSession(
                project: "rdoc",
                projectPath: "/Users/test/projects/../projects/rdoc",
                endedAt: now
            ),
            mockSession(
                project: "rdoc",
                projectPath: canonicalPath,
                endedAt: now.addingTimeInterval(-60)
            ),
        ]

        let result = recentProjects(from: sessions, existingPaths: [canonicalPath])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].projectPath, canonicalPath)
        XCTAssertEqual(result[0].sessionCount, 2)
    }

    func testArchiveSessionSkipsDesktopAppSessions() {
        let claudeTerminal = TerminalInfo(
            program: "", sessionId: nil, tty: nil,
            bundleId: "com.anthropic.claudefordesktop"
        )
        let session = mockSession(project: "claude-thing", terminal: claudeTerminal)
        let archived = sut.archiveSession(session)
        XCTAssertFalse(archived, "Desktop-app sessions must not be archived")

        // No history file should have been written.
        let files = try? FileManager.default.contentsOfDirectory(
            at: historyDir, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files?.count, 0)
    }

    func testBuildRecentProjectsPopulatesLastEditor() {
        let session = Session(
            sessionId: "test",
            projectPath: "/Users/test/app",
            projectName: "app",
            branch: "main",
            status: .idle,
            lastPrompt: nil,
            lastActivity: Date(),
            startedAt: Date(),
            terminal: TerminalInfo(program: "Cursor"),
            pid: nil,
            lastTool: nil,
            lastToolDetail: nil,
            notificationMessage: nil,
            endedAt: Date()
        )
        let result = recentProjects(from: [session])
        XCTAssertEqual(result[0].lastEditor, "Cursor")
    }

    func testBuildRecentProjectsIgnoresUnknownProgramAsProjectOpener() {
        let session = mockSession(
            project: "agent-created",
            terminal: TerminalInfo(program: "codex")
        )
        let result = recentProjects(from: [session])
        XCTAssertEqual(result[0].projectName, "agent-created")
        XCTAssertNil(result[0].lastEditor)
    }

    func testBuildRecentProjectsKeepsAgentMetadataSeparateFromProjectOpener() {
        let session = mockSession(
            project: "agent-created",
            terminal: TerminalInfo(program: "Claude Code"),
            source: Session.ccSource
        )
        let result = recentProjects(from: [session])
        XCTAssertNil(result[0].lastEditor)
        XCTAssertEqual(result[0].lastAgent, "Claude Code")
    }

    func testBuildRecentProjectsKeepsKnownTerminalProgramAsProjectOpener() {
        let session = mockSession(
            project: "terminal-created",
            terminal: TerminalInfo(
                program: "ghostty",
                sessionId: nil,
                tty: nil,
                bundleId: "com.mitchellh.ghostty"
            )
        )
        let result = recentProjects(from: [session])
        XCTAssertEqual(result[0].projectName, "terminal-created")
        XCTAssertEqual(result[0].lastEditor, "Ghostty")
    }

    func testRecentProjectMetadataSkipsUnknownBranch() {
        let project = RecentProject(
            projectPath: NSHomeDirectory() + "/projects/cctop",
            projectName: "cctop",
            lastBranch: "unknown",
            lastSessionAt: Date(),
            sessionCount: 4,
            lastEditor: nil,
            lastAgent: "Codex",
            workspaceFile: nil
        )
        XCTAssertEqual(project.pathContext, "~/projects/cctop")
        XCTAssertEqual(project.metadataEvidenceText, "Codex \u{00B7} 4 sessions")
        XCTAssertEqual(project.metadataText, "~/projects/cctop \u{00B7} Codex \u{00B7} 4 sessions")
    }

    func testRecentProjectMetadataIncludesMeaningfulBranch() {
        let project = RecentProject(
            projectPath: NSHomeDirectory() + "/projects/cctop",
            projectName: "cctop",
            lastBranch: "master",
            lastSessionAt: Date(),
            sessionCount: 1,
            lastEditor: "Cursor",
            lastAgent: "Claude Code",
            workspaceFile: nil
        )
        XCTAssertEqual(project.pathContext, "~/projects/cctop")
        XCTAssertEqual(project.metadataEvidenceText, "master \u{00B7} Claude Code \u{00B7} 1 session")
        XCTAssertEqual(project.metadataText, "~/projects/cctop \u{00B7} master \u{00B7} Claude Code \u{00B7} 1 session")
    }

    func testRecentProjectKnownTerminalOpenerUsesTerminalActionCopy() {
        let project = RecentProject(
            projectPath: NSHomeDirectory() + "/projects/irb",
            projectName: "irb",
            lastBranch: "master",
            lastSessionAt: Date(),
            sessionCount: 2,
            lastEditor: "Ghostty",
            lastAgent: "Claude Code",
            workspaceFile: nil
        )

        XCTAssertTrue(project.opensWithProjectApp)
        XCTAssertEqual(project.editorIcon, "terminal")
        XCTAssertEqual(project.openActionLabel, "Open in Ghostty")
    }

    func testRecentProjectAgentOpenerUsesFolderActionCopy() {
        let project = RecentProject(
            projectPath: NSHomeDirectory() + "/projects/cctop",
            projectName: "cctop",
            lastBranch: "master",
            lastSessionAt: Date(),
            sessionCount: 1,
            lastEditor: "Codex",
            lastAgent: "Codex",
            workspaceFile: nil
        )

        XCTAssertFalse(project.opensWithProjectApp)
        XCTAssertEqual(project.editorIcon, "folder")
        XCTAssertEqual(project.openActionLabel, "Open Project Folder")
    }

    func testRebuildCachesDecodedHistorySessionsAndKeepsCacheOnNoopRebuild() throws {
        let endedAt = Date(timeIntervalSince1970: 1_000)
        let session = mockSession(project: "cached-app", endedAt: endedAt, lastActivity: endedAt)
        try session.writeToFile(path: historyDir.appendingPathComponent("cached.json").path)

        XCTAssertTrue(sut.rebuildRecentProjects())
        XCTAssertEqual(sut.lastDecodedHistorySessions.map(\.projectName), ["cached-app"])

        XCTAssertFalse(sut.rebuildRecentProjects())
        XCTAssertEqual(sut.lastDecodedHistorySessions.map(\.projectName), ["cached-app"])
    }

    // MARK: - relativeDescription tests

    func testRelativeTimeJustNow() {
        let date = Date()
        XCTAssertEqual(date.relativeDescription, "just now")
    }

    func testRelativeTimeSeconds() {
        let date = Date().addingTimeInterval(-45)
        XCTAssertEqual(date.relativeDescription, "45s ago")
    }

    func testRelativeTimeBoundary59s() {
        let date = Date().addingTimeInterval(-59)
        XCTAssertEqual(date.relativeDescription, "59s ago")
    }

    func testRelativeTimeBoundary60s() {
        let date = Date().addingTimeInterval(-60)
        XCTAssertEqual(date.relativeDescription, "1m ago")
    }

    func testRelativeTimeMinutes() {
        let date = Date().addingTimeInterval(-300)
        XCTAssertEqual(date.relativeDescription, "5m ago")
    }

    func testRelativeTimeBoundary3600s() {
        let date = Date().addingTimeInterval(-3600)
        XCTAssertEqual(date.relativeDescription, "1h ago")
    }

    func testRelativeTimeHours() {
        let date = Date().addingTimeInterval(-7200)
        XCTAssertEqual(date.relativeDescription, "2h ago")
    }

    func testRelativeTimeBoundary86400s() {
        let date = Date().addingTimeInterval(-86400)
        XCTAssertEqual(date.relativeDescription, "1d ago")
    }

    func testRelativeTimeDays() {
        let date = Date().addingTimeInterval(-259200)
        XCTAssertEqual(date.relativeDescription, "3d ago")
    }

    func testRelativeTimeFutureDate() {
        let date = Date().addingTimeInterval(60)
        XCTAssertEqual(date.relativeDescription, "just now")
    }

    func testRelativeTimeUsesProvidedReferenceDate() {
        let date = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            date.relativeDescription(asOf: date.addingTimeInterval(120)),
            "2m ago"
        )
    }

    @MainActor
    func testHistoryManagerDoesNotPublishUnchangedRecentProjects() throws {
        let root = NSTemporaryDirectory() + "cctop-history-publish-\(UUID().uuidString)"
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        var session = Session(
            sessionId: "recent-session",
            projectPath: "/tmp/recent",
            branch: "main",
            terminal: TerminalInfo()
        )
        session.endedAt = Date(timeIntervalSince1970: 1_000)
        try session.writeToFile(path: (historyDir as NSString).appendingPathComponent("recent.json"))

        let manager = HistoryManager(historyDir: URL(fileURLWithPath: historyDir))
        var publishCount = 0
        let cancellable = manager.objectWillChange.sink { _ in publishCount += 1 }

        let didRebuild = manager.rebuildRecentProjects()

        XCTAssertFalse(didRebuild)
        XCTAssertEqual(publishCount, 0)
        _ = cancellable
    }
}
