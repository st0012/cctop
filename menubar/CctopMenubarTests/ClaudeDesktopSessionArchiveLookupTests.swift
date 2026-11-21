import XCTest
@testable import CctopMenubar

final class ClaudeDesktopSessionArchiveLookupTests: XCTestCase {
    func testArchivedClaudeSessionIDsDistinguishesMissingFromUnreadable() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-lookup-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let missing = (root as NSString).appendingPathComponent("missing")
        XCTAssertEqual(
            ClaudeDesktopSessionArchiveLookup(sessionsDirectory: missing).archivedSessionIDs(matching: ["x"]),
            []
        )

        let corruptDir = (root as NSString).appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(atPath: corruptDir, withIntermediateDirectories: true)
        let corrupt = (corruptDir as NSString).appendingPathComponent("local_corrupt.json")
        try Data(#"{"cliSessionId":"x","isArchived":"not-a-boolean"}"#.utf8)
            .write(to: URL(fileURLWithPath: corrupt))
        XCTAssertNil(
            ClaudeDesktopSessionArchiveLookup(sessionsDirectory: corruptDir)
                .archivedSessionIDs(matching: ["x"])
        )
    }

    func testArchivedClaudeSessionIDsTreatsMalformedPossibleMatchAsUnreadable() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-malformed-match-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let malformed = (root as NSString).appendingPathComponent("local_malformed.json")
        try Data(#"{"cliSessionId":target-session,"title":"broken"}"#.utf8)
            .write(to: URL(fileURLWithPath: malformed))

        XCTAssertNil(
            ClaudeDesktopSessionArchiveLookup(sessionsDirectory: root)
                .archivedSessionIDs(matching: ["target-session"])
        )
    }

    func testArchivedClaudeSessionIDsDoesNotMatchTargetOutsideCliSessionID() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-non-id-match-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let metadata = (root as NSString).appendingPathComponent("local_other.json")
        try Data(#"{"cliSessionId":"other-session","title":"target-session","isArchived":true}"#.utf8)
            .write(to: URL(fileURLWithPath: metadata))

        XCTAssertEqual(
            ClaudeDesktopSessionArchiveLookup(sessionsDirectory: root)
                .archivedSessionIDs(matching: ["target-session"]),
            []
        )
    }

    func testArchivedClaudeSessionIDsContinuesPastNestedCliSessionID() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-nested-cli-session-id-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let metadata = (root as NSString).appendingPathComponent("local_nested.json")
        try Data(
            #"{"metadata":{"cliSessionId":"other-session"},"cliSessionId":"target-session","isArchived":true}"#.utf8
        ).write(to: URL(fileURLWithPath: metadata))

        XCTAssertEqual(
            ClaudeDesktopSessionArchiveLookup(sessionsDirectory: root)
                .archivedSessionIDs(matching: ["target-session"]),
            ["target-session"]
        )
    }

    func testArchivedClaudeSessionIDsAcceptsNumericTimestamps() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-numeric-lookup-\(UUID().uuidString)"
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "numeric-timestamp-session",
            isArchived: true,
            lastActivityAt: 1_779_281_104_333
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        XCTAssertEqual(
            ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir)
                .archivedSessionIDs(matching: ["numeric-timestamp-session"]),
            ["numeric-timestamp-session"]
        )
    }

    func testArchivedClaudeSessionIDsUsesNewestNumericTimestamp() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-numeric-order-\(UUID().uuidString)"
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "numeric-order-session",
            isArchived: false,
            lastActivityAt: 99
        )
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "numeric-order-session",
            isArchived: true,
            lastActivityAt: 1_000
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        XCTAssertEqual(
            ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir)
                .archivedSessionIDs(matching: ["numeric-order-session"]),
            ["numeric-order-session"]
        )
    }

    func testDesktopSessionIDMapsHookSessionIDToDesktopSessionUUID() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-desktop-id-\(UUID().uuidString)"
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        let hookSessionID = "002fb6fa-eae0-4631-94bd-84071dbd21d8"
        let desktopSessionID = "7b0c1a52-3f6e-4d7a-9c1b-2e5f8a4d6c30"
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: hookSessionID,
            isArchived: false,
            sessionId: "local_\(desktopSessionID)"
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        let lookup = ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir)
        XCTAssertEqual(lookup.desktopSessionID(forCLISessionID: hookSessionID), desktopSessionID)
        XCTAssertNil(lookup.desktopSessionID(forCLISessionID: "5d3e9f10-8a2b-4c6d-b7e1-0f4a9c2d8e57"))
    }

    func testDesktopSessionIDRequiresLocalUUIDSessionID() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-desktop-id-shape-\(UUID().uuidString)"
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        let hookSessionID = "002fb6fa-eae0-4631-94bd-84071dbd21d8"
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: hookSessionID,
            isArchived: false,
            sessionId: "session_01ABCDEF"
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        XCTAssertNil(
            ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir)
                .desktopSessionID(forCLISessionID: hookSessionID)
        )
    }

    func testClaudeDesktopMetadataSnapshotIncludesProjectNameFromOriginCwd() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-project-name-\(UUID().uuidString)"
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "claude-desktop-project",
            isArchived: false,
            originCwd: "/Users/dev/projects/cctop",
            worktreeName: "generated-worktree"
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        let snapshot = ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir)
            .metadataSnapshot(matching: ["claude-desktop-project"])
        XCTAssertEqual(snapshot?.projectNamesBySessionID["claude-desktop-project"], "cctop")
    }

    func testClaudeDesktopMetadataSnapshotFallsBackToWorktreeName() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-project-name-fallback-\(UUID().uuidString)"
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "claude-desktop-project",
            isArchived: false,
            worktreeName: "cctop"
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        let snapshot = ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir)
            .metadataSnapshot(matching: ["claude-desktop-project"])
        XCTAssertEqual(snapshot?.projectNamesBySessionID["claude-desktop-project"], "cctop")
    }

    func testClaudeDesktopMetadataSnapshotIgnoresNonStringProjectNameFields() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-project-name-lossy-\(UUID().uuidString)"
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "claude-desktop-project",
            isArchived: true,
            originCwd: 123,
            worktreeName: ["generated-worktree"]
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        let snapshot = ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir)
            .metadataSnapshot(matching: ["claude-desktop-project"])
        XCTAssertEqual(snapshot?.archivedSessionIDs, ["claude-desktop-project"])
        XCTAssertEqual(snapshot?.projectNamesBySessionID, [:])
    }

    func testClaudeDesktopMetadataSnapshotCachesUnchangedFiles() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-cache-\(UUID().uuidString)"
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "cached-claude-session",
            isArchived: false,
            originCwd: "/Users/dev/projects/cctop"
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        var readCount = 0
        let lookup = ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir) { url in
            readCount += 1
            return try? Data(contentsOf: url)
        }

        let first = lookup.metadataSnapshot(matching: ["cached-claude-session"])
        XCTAssertEqual(first?.projectNamesBySessionID["cached-claude-session"], "cctop")
        let readsAfterFirstSnapshot = readCount

        let second = lookup.metadataSnapshot(matching: ["cached-claude-session"])
        XCTAssertEqual(second, first)
        XCTAssertEqual(readCount, readsAfterFirstSnapshot)
    }

    func testClaudeDesktopMetadataSnapshotCacheIsReusableAcrossQuerySets() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-cross-query-cache-\(UUID().uuidString)"
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "cached-claude-one",
            isArchived: false,
            originCwd: "/Users/dev/projects/one"
        )
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "cached-claude-two",
            isArchived: true,
            originCwd: "/Users/dev/projects/two"
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        var readCount = 0
        let lookup = ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir) { url in
            readCount += 1
            return try? Data(contentsOf: url)
        }

        let first = lookup.metadataSnapshot(matching: ["cached-claude-one"])
        XCTAssertEqual(first?.projectNamesBySessionID["cached-claude-one"], "one")
        let readsAfterFirstSnapshot = readCount

        let second = lookup.metadataSnapshot(matching: ["cached-claude-two"])
        XCTAssertEqual(second?.archivedSessionIDs, ["cached-claude-two"])
        XCTAssertEqual(second?.projectNamesBySessionID["cached-claude-two"], "two")
        XCTAssertEqual(readCount, readsAfterFirstSnapshot)
    }

    func testClaudeDesktopMetadataSnapshotDoesNotCacheTransientUnreadability() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-transient-cache-\(UUID().uuidString)"
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "transient-claude-session",
            isArchived: true
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        var failNextRead = true
        let lookup = ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir) { url in
            if failNextRead {
                failNextRead = false
                return nil
            }
            return try? Data(contentsOf: url)
        }

        XCTAssertNil(lookup.metadataSnapshot(matching: ["transient-claude-session"]))

        let second = lookup.metadataSnapshot(matching: ["transient-claude-session"])
        XCTAssertEqual(second?.archivedSessionIDs, ["transient-claude-session"])
    }
}
