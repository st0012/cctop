import XCTest
@testable import CctopMenubar

final class SessionNameLookupTests: XCTestCase {
    private var tmpDir: String!

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "cctop-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
        super.tearDown()
    }

    // MARK: - lookupSessionName (top-level)

    func testNilTranscriptPathReturnsNil() {
        let result = SessionNameLookup.lookupSessionName(transcriptPath: nil, sessionId: "s1")
        XCTAssertNil(result)
    }

    func testEmptyTranscriptPathReturnsNil() {
        let result = SessionNameLookup.lookupSessionName(transcriptPath: "", sessionId: "s1")
        XCTAssertNil(result)
    }

    func testMissingTranscriptFileReturnsNil() {
        let result = SessionNameLookup.lookupSessionName(
            transcriptPath: tmpDir + "/nonexistent.jsonl", sessionId: "s1"
        )
        XCTAssertNil(result)
    }

    // MARK: - Transcript JSONL lookup

    func testFindsCustomTitleInTranscript() {
        let path = tmpDir + "/transcript.jsonl"
        let content = """
        {"type":"system","content":"hello"}
        {"type":"custom-title","customTitle":"my feature"}
        {"type":"assistant","content":"response"}
        """
        try! content.write(toFile: path, atomically: true, encoding: .utf8)

        let result = SessionNameLookup.lookupSessionName(
            transcriptPath: path, sessionId: "s1"
        )
        XCTAssertEqual(result, "my feature")
    }

    func testReturnsLastCustomTitleWhenMultiple() {
        let path = tmpDir + "/transcript.jsonl"
        let content = """
        {"type":"custom-title","customTitle":"first name"}
        {"type":"assistant","content":"response"}
        {"type":"custom-title","customTitle":"renamed"}
        """
        try! content.write(toFile: path, atomically: true, encoding: .utf8)

        let result = SessionNameLookup.lookupSessionName(
            transcriptPath: path, sessionId: "s1"
        )
        XCTAssertEqual(result, "renamed")
    }

    func testNoCustomTitleInTranscriptReturnsNil() {
        let path = tmpDir + "/transcript.jsonl"
        let content = """
        {"type":"system","content":"hello"}
        {"type":"assistant","content":"response"}
        """
        try! content.write(toFile: path, atomically: true, encoding: .utf8)

        let result = SessionNameLookup.lookupSessionName(
            transcriptPath: path, sessionId: "s1"
        )
        XCTAssertNil(result)
    }

    func testEmptyCustomTitleIsIgnored() {
        let path = tmpDir + "/transcript.jsonl"
        let content = """
        {"type":"custom-title","customTitle":""}
        """
        try! content.write(toFile: path, atomically: true, encoding: .utf8)

        let result = SessionNameLookup.lookupSessionName(
            transcriptPath: path, sessionId: "s1"
        )
        XCTAssertNil(result)
    }

    // MARK: - sessions-index.json fallback

    func testFallsBackToSessionsIndex() {
        // Transcript without custom-title
        let transcriptPath = tmpDir + "/transcript.jsonl"
        try! "{\"type\":\"system\"}\n".write(toFile: transcriptPath, atomically: true, encoding: .utf8)

        // sessions-index.json in same directory
        let indexPath = tmpDir + "/sessions-index.json"
        let index = """
        {"entries":[{"sessionId":"s1","customTitle":"from index"}]}
        """
        try! index.write(toFile: indexPath, atomically: true, encoding: .utf8)

        let result = SessionNameLookup.lookupSessionName(
            transcriptPath: transcriptPath, sessionId: "s1"
        )
        XCTAssertEqual(result, "from index")
    }

    func testIndexNoMatchingSessionReturnsNil() {
        let transcriptPath = tmpDir + "/transcript.jsonl"
        try! "{\"type\":\"system\"}\n".write(toFile: transcriptPath, atomically: true, encoding: .utf8)

        let indexPath = tmpDir + "/sessions-index.json"
        let index = """
        {"entries":[{"sessionId":"other","customTitle":"other title"}]}
        """
        try! index.write(toFile: indexPath, atomically: true, encoding: .utf8)

        let result = SessionNameLookup.lookupSessionName(
            transcriptPath: transcriptPath, sessionId: "s1"
        )
        XCTAssertNil(result)
    }

    func testIndexMatchWithoutCustomTitleReturnsNil() {
        let transcriptPath = tmpDir + "/transcript.jsonl"
        try! "{\"type\":\"system\"}\n".write(toFile: transcriptPath, atomically: true, encoding: .utf8)

        let indexPath = tmpDir + "/sessions-index.json"
        let index = """
        {"entries":[{"sessionId":"s1","name":"some name"}]}
        """
        try! index.write(toFile: indexPath, atomically: true, encoding: .utf8)

        let result = SessionNameLookup.lookupSessionName(
            transcriptPath: transcriptPath, sessionId: "s1"
        )
        XCTAssertNil(result)
    }

    func testIndexReturnsLastTitleWhenMultipleEntries() {
        let transcriptPath = tmpDir + "/transcript.jsonl"
        try! "{\"type\":\"system\"}\n".write(toFile: transcriptPath, atomically: true, encoding: .utf8)

        let indexPath = tmpDir + "/sessions-index.json"
        let index = """
        {"entries":[
            {"sessionId":"s1","customTitle":"first name"},
            {"sessionId":"other","customTitle":"unrelated"},
            {"sessionId":"s1","customTitle":"renamed"}
        ]}
        """
        try! index.write(toFile: indexPath, atomically: true, encoding: .utf8)

        let result = SessionNameLookup.lookupSessionName(
            transcriptPath: transcriptPath, sessionId: "s1"
        )
        XCTAssertEqual(result, "renamed")
    }

    func testTranscriptTakesPriorityOverIndex() {
        let transcriptPath = tmpDir + "/transcript.jsonl"
        let content = """
        {"type":"custom-title","customTitle":"from transcript"}
        """
        try! content.write(toFile: transcriptPath, atomically: true, encoding: .utf8)

        let indexPath = tmpDir + "/sessions-index.json"
        let index = """
        {"entries":[{"sessionId":"s1","customTitle":"from index"}]}
        """
        try! index.write(toFile: indexPath, atomically: true, encoding: .utf8)

        let result = SessionNameLookup.lookupSessionName(
            transcriptPath: transcriptPath, sessionId: "s1"
        )
        XCTAssertEqual(result, "from transcript")
    }

    // MARK: - Codex session_index.jsonl lookup

    func testCodex_findsThreadNameByExactSessionId() {
        let indexPath = tmpDir + "/session_index.jsonl"
        let content = """
        {"id":"019e1ef6-0cde-77a2-a873-ddcb33240005","thread_name":"Help me create a zh-tw draft","updated_at":"2026-05-13T01:31:42.415727Z"}
        {"id":"019e1eff-3374-74b0-8d3d-6fba94e7d75f","thread_name":"Investigate tanstack incident","updated_at":"2026-05-13T01:42:01.071611Z"}
        {"id":"019e415d-b7a1-77d2-b019-1288a45e57f3","thread_name":"Review project architecture","updated_at":"2026-05-19T17:52:37.293141Z"}
        """
        try! content.write(toFile: indexPath, atomically: true, encoding: .utf8)

        let result = SessionNameLookup.lookupCodexThreadName(
            sessionId: "019e415d-b7a1-77d2-b019-1288a45e57f3",
            indexPath: indexPath
        )
        XCTAssertEqual(result, "Review project architecture")
    }

    func testCodex_returnsLatestEntryWhenSessionIdAppearsTwice() {
        let indexPath = tmpDir + "/session_index.jsonl"
        let content = """
        {"id":"s1","thread_name":"original","updated_at":"2026-05-19T17:00:00Z"}
        {"id":"other","thread_name":"unrelated","updated_at":"2026-05-19T17:30:00Z"}
        {"id":"s1","thread_name":"renamed","updated_at":"2026-05-19T18:00:00Z"}
        """
        try! content.write(toFile: indexPath, atomically: true, encoding: .utf8)

        let result = SessionNameLookup.lookupCodexThreadName(
            sessionId: "s1", indexPath: indexPath
        )
        XCTAssertEqual(result, "renamed")
    }

    func testCodex_missingFileReturnsNil() {
        let result = SessionNameLookup.lookupCodexThreadName(
            sessionId: "s1", indexPath: tmpDir + "/nonexistent.jsonl"
        )
        XCTAssertNil(result)
    }

    func testCodex_noMatchingSessionIdReturnsNil() {
        let indexPath = tmpDir + "/session_index.jsonl"
        let content = """
        {"id":"other","thread_name":"unrelated","updated_at":"2026-05-19T17:00:00Z"}
        """
        try! content.write(toFile: indexPath, atomically: true, encoding: .utf8)

        let result = SessionNameLookup.lookupCodexThreadName(
            sessionId: "s1", indexPath: indexPath
        )
        XCTAssertNil(result)
    }

    func testCodex_emptyThreadNameIsIgnored() {
        let indexPath = tmpDir + "/session_index.jsonl"
        let content = """
        {"id":"s1","thread_name":"","updated_at":"2026-05-19T17:00:00Z"}
        """
        try! content.write(toFile: indexPath, atomically: true, encoding: .utf8)

        let result = SessionNameLookup.lookupCodexThreadName(
            sessionId: "s1", indexPath: indexPath
        )
        XCTAssertNil(result)
    }

    func testCodex_skipsLinesContainingIdSubstringButDifferentId() {
        // Guard against the contains() shortcut matching the wrong line —
        // e.g. a session_id that's a prefix of another.
        let indexPath = tmpDir + "/session_index.jsonl"
        let content = """
        {"id":"s1-prefix-of-something-else","thread_name":"wrong match","updated_at":"2026-05-19T17:00:00Z"}
        {"id":"s1","thread_name":"correct match","updated_at":"2026-05-19T18:00:00Z"}
        """
        try! content.write(toFile: indexPath, atomically: true, encoding: .utf8)

        let result = SessionNameLookup.lookupCodexThreadName(
            sessionId: "s1", indexPath: indexPath
        )
        XCTAssertEqual(result, "correct match")
    }
}
