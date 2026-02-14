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
}
