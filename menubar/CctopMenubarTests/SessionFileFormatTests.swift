import XCTest
@testable import CctopMenubar

final class SessionFileFormatTests: XCTestCase {
    func testLegacyUUIDFilenameClassification() {
        // Pre-PID files were keyed by a bare session UUID -> should be removed.
        XCTAssertTrue(SessionManager.isLegacyUUIDFilename("019e4b0c-9473-7a33-a4b9-749fd2c83a9e"))
        // PID-keyed files are numeric -> keep.
        XCTAssertFalse(SessionManager.isLegacyUUIDFilename("31349"))
        // Codex per-conversation files -> keep.
        XCTAssertFalse(SessionManager.isLegacyUUIDFilename("codex-019e4b0c-9473-7a33-a4b9-749fd2c83a9e"))
    }

    @MainActor
    func testDecodedSessionsReusesCachedSessionForUnchangedFileFingerprint() throws {
        let root = NSTemporaryDirectory() + "cctop-session-decode-cache-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        let sessionURL = URL(fileURLWithPath: (sessionsDir as NSString).appendingPathComponent("cached.json"))
        try Session(sessionId: "cached-session", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
            .writeToFile(path: sessionURL.path)
        let originalMtime = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: originalMtime], ofItemAtPath: sessionURL.path)

        XCTAssertEqual(manager.decodedSessions(from: [sessionURL]).map(\.session.sessionId), ["cached-session"])

        let values = try sessionURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let originalSize = try XCTUnwrap(values.fileSize)
        try Data(repeating: UInt8(ascii: "{"), count: originalSize).write(to: sessionURL)
        try FileManager.default.setAttributes([.modificationDate: originalMtime], ofItemAtPath: sessionURL.path)

        XCTAssertEqual(manager.decodedSessions(from: [sessionURL]).map(\.session.sessionId), ["cached-session"])
    }

    @MainActor
    func testDecodedSessionsInvalidatesCacheWhenFileFingerprintChanges() throws {
        let root = NSTemporaryDirectory() + "cctop-session-decode-cache-change-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        let sessionURL = URL(fileURLWithPath: (sessionsDir as NSString).appendingPathComponent("cached.json"))
        try Session(sessionId: "cached-session", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
            .writeToFile(path: sessionURL.path)
        let originalMtime = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: originalMtime], ofItemAtPath: sessionURL.path)

        XCTAssertEqual(manager.decodedSessions(from: [sessionURL]).map(\.session.sessionId), ["cached-session"])

        try Session(sessionId: "changed-session", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
            .writeToFile(path: sessionURL.path)
        try FileManager.default.setAttributes(
            [.modificationDate: originalMtime.addingTimeInterval(10)],
            ofItemAtPath: sessionURL.path
        )

        XCTAssertEqual(manager.decodedSessions(from: [sessionURL]).map(\.session.sessionId), ["changed-session"])
    }
}
