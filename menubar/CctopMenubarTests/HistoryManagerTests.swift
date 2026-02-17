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
        endedAt: Date? = nil,
        lastActivity: Date = Date()
    ) -> Session {
        Session(
            sessionId: UUID().uuidString,
            projectPath: "/Users/test/\(project)",
            projectName: project,
            branch: "main",
            status: .idle,
            lastPrompt: nil,
            lastActivity: lastActivity,
            startedAt: lastActivity,
            terminal: TerminalInfo(program: "Code"),
            pid: nil,
            lastTool: nil,
            lastToolDetail: nil,
            notificationMessage: nil,
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
        let result = HistoryManager.buildRecentProjects(from: sessions)
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
        let result = HistoryManager.buildRecentProjects(
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
        let result = HistoryManager.buildRecentProjects(from: sessions)
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
        let result = HistoryManager.buildRecentProjects(from: sessions)
        XCTAssertEqual(result.count, 10)
    }

    func testBuildRecentProjectsUsesEndedAt() {
        let now = Date()
        let session = mockSession(
            project: "app",
            endedAt: now.addingTimeInterval(-60),
            lastActivity: now.addingTimeInterval(-7200)
        )
        let result = HistoryManager.buildRecentProjects(from: [session])
        XCTAssertEqual(result.count, 1)
        // lastSessionAt should use endedAt (60s ago), not lastActivity (2h ago)
        let elapsed = Int(-result[0].lastSessionAt.timeIntervalSinceNow)
        XCTAssertTrue(elapsed < 120, "Should use endedAt, not lastActivity")
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
        let result = HistoryManager.buildRecentProjects(from: [session])
        XCTAssertEqual(result[0].lastEditor, "Cursor")
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
}
