import Darwin
import XCTest
@testable import CctopMenubar

final class CodexThreadArchiveLookupTests: XCTestCase {
    private enum CodexRolloutPlacement {
        case active
        case archived
    }

    private struct CodexArchivePlacementFixture {
        let root: String
        let stateDB: String
        let threadID: String
        let activePath: String
        let archivedPath: String

        func rolloutPath(for placement: CodexRolloutPlacement) -> String {
            switch placement {
            case .active:
                return activePath
            case .archived:
                return archivedPath
            }
        }
    }

    private let codexStateEnvironmentNames = ["CCTOP_CODEX_STATE_DB", "CODEX_HOME", "CODEX_SQLITE_HOME"]

    private func writeCodexRolloutMetadata(path: String, threadID: String, originator: String) throws {
        let object: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "id": threadID,
                "originator": originator,
                "source": "exec"
            ]
        ]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0a)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func savedEnvironment(_ names: [String]) -> [String: String?] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            (name, getenv(name).map { String(cString: $0) })
        })
    }

    private func restoreEnvironment(_ saved: [String: String?]) {
        for (name, value) in saved {
            if let value {
                setenv(name, value, 1)
            } else {
                unsetenv(name)
            }
        }
    }

    private func withPreservedCodexStateEnvironment(_ body: () throws -> Void) rethrows {
        let env = savedEnvironment(codexStateEnvironmentNames)
        defer { restoreEnvironment(env) }
        try body()
    }

    private func makeCodexArchivePlacementFixture(
        rootPrefix: String,
        threadID: String = "019ec6c4-23ac-7a82-9f5b-812d0b743430"
    ) throws -> CodexArchivePlacementFixture {
        let root = NSTemporaryDirectory() + "\(rootPrefix)-\(UUID().uuidString)"
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        let activeDir = (root as NSString).appendingPathComponent("sessions/2026/06/14")
        let archivedDir = (root as NSString).appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(atPath: activeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: archivedDir, withIntermediateDirectories: true)

        let filename = "rollout-2026-06-14T16-33-23-\(threadID).jsonl"
        return CodexArchivePlacementFixture(
            root: root,
            stateDB: stateDB,
            threadID: threadID,
            activePath: (activeDir as NSString).appendingPathComponent(filename),
            archivedPath: (archivedDir as NSString).appendingPathComponent(filename)
        )
    }

    private func writeCodexThreadState(
        _ fixture: CodexArchivePlacementFixture,
        sqliteArchived: Bool,
        rolloutPlacement: CodexRolloutPlacement
    ) throws {
        try writeCodexStateDatabase(
            path: fixture.stateDB,
            archivedThreads: sqliteArchived ? [fixture.threadID] : [],
            userExecThreads: sqliteArchived ? [] : [fixture.threadID]
        )
        try executeSQLite(
            """
            UPDATE threads
            SET rollout_path = \(sqlValue(fixture.rolloutPath(for: rolloutPlacement))),
                archived = \(sqliteArchived ? 1 : 0)
            WHERE id = \(sqlValue(fixture.threadID));
            """,
            path: fixture.stateDB
        )
    }

    private func writeCodexRollout(
        _ placement: CodexRolloutPlacement,
        in fixture: CodexArchivePlacementFixture,
        originator: String = "Codex Desktop"
    ) throws {
        try writeCodexRolloutMetadata(
            path: fixture.rolloutPath(for: placement),
            threadID: fixture.threadID,
            originator: originator
        )
    }

    private func archivedThreadIDs(
        _ lookup: CodexThreadArchiveLookup,
        in fixture: CodexArchivePlacementFixture
    ) -> Set<String>? {
        lookup.archivedThreadIDs(matching: [fixture.threadID])
    }

    func testCodexStateDatabaseCandidatesUseExplicitOverrideBeforeRuntimeAndCodexHome() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-state-db-override-\(UUID().uuidString)"
        let codexHome = (root as NSString).appendingPathComponent("codex")
        let override = (root as NSString).appendingPathComponent("custom.sqlite")
        let runtimeSQLiteHome = (root as NSString).appendingPathComponent("runtime-sqlite")
        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        withPreservedCodexStateEnvironment {
            setenv("CCTOP_CODEX_STATE_DB", override, 1)
            setenv("CODEX_HOME", codexHome, 1)
            setenv("CODEX_SQLITE_HOME", (root as NSString).appendingPathComponent("sqlite"), 1)

            XCTAssertEqual(Config.codexStateDatabaseCandidates(desktopSQLiteHome: runtimeSQLiteHome), [Config.standardizedPath(override)])
        }
    }

    func testCodexStateDatabaseCandidatesPreferDesktopRuntimeSQLiteHome() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-runtime-state-db-\(UUID().uuidString)"
        let codexHome = (root as NSString).appendingPathComponent("codex")
        let runtimeSQLiteHome = (root as NSString).appendingPathComponent("runtime-sqlite")
        let configSQLiteHome = (root as NSString).appendingPathComponent("from-config")
        let runtimeDB = (runtimeSQLiteHome as NSString).appendingPathComponent("state_5.sqlite")
        let configDB = (configSQLiteHome as NSString).appendingPathComponent("state_5.sqlite")
        let nestedDB = (codexHome as NSString).appendingPathComponent("sqlite/state_5.sqlite")
        let rootDB = (codexHome as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        let configPath = (codexHome as NSString).appendingPathComponent("config.toml")
        try """
        model = "gpt-5"
        sqlite_home = "\(configSQLiteHome)"
        """.write(toFile: configPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: root) }

        withPreservedCodexStateEnvironment {
            setenv("CODEX_HOME", codexHome, 1)
            setenv("CODEX_SQLITE_HOME", (root as NSString).appendingPathComponent("from-env"), 1)
            unsetenv("CCTOP_CODEX_STATE_DB")

            XCTAssertEqual(
                Config.codexStateDatabaseCandidates(desktopSQLiteHome: runtimeSQLiteHome),
                [
                    Config.standardizedPath(runtimeDB),
                    Config.standardizedPath(configDB),
                    Config.standardizedPath(nestedDB),
                    Config.standardizedPath(rootDB)
                ]
            )
        }
    }

    func testCodexStateDatabaseCandidatesDecodeTomlEscapedConfigSQLiteHome() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-config-state-db-\(UUID().uuidString)"
        let codexHome = (root as NSString).appendingPathComponent("codex")
        let configSQLiteHome = (root as NSString).appendingPathComponent("from-config")
        let configDB = (configSQLiteHome as NSString).appendingPathComponent("state_5.sqlite")
        let nestedDB = (codexHome as NSString).appendingPathComponent("sqlite/state_5.sqlite")
        let rootDB = (codexHome as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        let configPath = (codexHome as NSString).appendingPathComponent("config.toml")
        let escapedConfigSQLiteHome = "\\u002F" + configSQLiteHome.dropFirst()
        try """
        sqlite_home = "\(escapedConfigSQLiteHome)"
        """.write(toFile: configPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: root) }

        withPreservedCodexStateEnvironment {
            setenv("CODEX_HOME", codexHome, 1)
            unsetenv("CODEX_SQLITE_HOME")
            unsetenv("CCTOP_CODEX_STATE_DB")

            XCTAssertEqual(
                Config.codexStateDatabaseCandidates(),
                [
                    Config.standardizedPath(configDB),
                    Config.standardizedPath(nestedDB),
                    Config.standardizedPath(rootDB)
                ]
            )
        }
    }

    // A missing DB means "no Codex state ⇒ nothing archived" → empty set (deletable). A DB that
    // exists but cannot be parsed means "unknown" → nil, which the GC path must treat as keep.
    func testArchivedThreadIDsDistinguishesMissingFromUnreadable() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-lookup-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let missing = (root as NSString).appendingPathComponent("missing.sqlite")
        XCTAssertEqual(CodexThreadArchiveLookup(stateDatabasePath: missing).archivedThreadIDs(matching: ["x"]), [])

        let corrupt = (root as NSString).appendingPathComponent("corrupt.sqlite")
        try Data("this is not a sqlite database".utf8).write(to: URL(fileURLWithPath: corrupt))
        XCTAssertNil(CodexThreadArchiveLookup(stateDatabasePath: corrupt).archivedThreadIDs(matching: ["x"]))
    }

    func testCodexThreadLookupFallsBackToLaterCandidateWhenPreferredDatabaseDoesNotContainThread() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-lookup-fallback-\(UUID().uuidString)"
        let preferredDB = (root as NSString).appendingPathComponent("runtime/state_5.sqlite")
        let fallbackDB = (root as NSString).appendingPathComponent("root/state_5.sqlite")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try writeCodexStateDatabase(path: preferredDB, archivedThreads: ["other-thread"])
        try writeCodexStateDatabase(path: fallbackDB, archivedThreads: ["target-thread"])

        let lookup = CodexThreadArchiveLookup(stateDatabasePaths: { [preferredDB, fallbackDB] })

        XCTAssertEqual(lookup.existingThreadIDs(matching: ["target-thread"]), ["target-thread"])
        XCTAssertEqual(lookup.archivedThreadIDs(matching: ["target-thread"]), ["target-thread"])
    }

    func testCodexThreadLookupKeepsPreferredCandidateWhenFallbackDisagreesForSameThread() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-lookup-conflict-\(UUID().uuidString)"
        let preferredDB = (root as NSString).appendingPathComponent("runtime/state_5.sqlite")
        let fallbackDB = (root as NSString).appendingPathComponent("root/state_5.sqlite")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try writeCodexStateDatabase(path: preferredDB, archivedThreads: [], userExecThreads: ["shared-thread"])
        try writeCodexStateDatabase(path: fallbackDB, archivedThreads: ["shared-thread"])

        let lookup = CodexThreadArchiveLookup(stateDatabasePaths: { [preferredDB, fallbackDB] })

        XCTAssertEqual(lookup.existingThreadIDs(matching: ["shared-thread"]), ["shared-thread"])
        XCTAssertEqual(lookup.archivedThreadIDs(matching: ["shared-thread"]), [])
    }

    func testCodexThreadLookupStopsOnUnreadablePreferredCandidate() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-lookup-unreadable-preferred-\(UUID().uuidString)"
        let preferredDB = (root as NSString).appendingPathComponent("runtime/state_5.sqlite")
        let fallbackDB = (root as NSString).appendingPathComponent("root/state_5.sqlite")
        try FileManager.default.createDirectory(
            atPath: (preferredDB as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        try Data("this is not a sqlite database".utf8).write(to: URL(fileURLWithPath: preferredDB))
        try writeCodexStateDatabase(path: fallbackDB, archivedThreads: ["target-thread"])

        let lookup = CodexThreadArchiveLookup(stateDatabasePaths: { [preferredDB, fallbackDB] })

        XCTAssertNil(lookup.existingThreadIDs(matching: ["target-thread"]))
        XCTAssertNil(lookup.archivedThreadIDs(matching: ["target-thread"]))
    }

    func testCodexThreadLookupKeepsEarlierAnswersWhenLaterCandidateIsUnreadable() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-lookup-unreadable-fallback-\(UUID().uuidString)"
        let preferredDB = (root as NSString).appendingPathComponent("runtime/state_5.sqlite")
        let fallbackDB = (root as NSString).appendingPathComponent("root/state_5.sqlite")
        try FileManager.default.createDirectory(
            atPath: (fallbackDB as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: root) }

        try writeCodexStateDatabase(path: preferredDB, archivedThreads: ["desktop-thread"])
        try executeSQLite(
            """
            UPDATE threads
            SET git_origin_url = 'git@github.com:st0012/cctop.git'
            WHERE id = 'desktop-thread';
            """,
            path: preferredDB
        )
        try Data("this is not a sqlite database".utf8).write(to: URL(fileURLWithPath: fallbackDB))

        let lookup = CodexThreadArchiveLookup(stateDatabasePaths: { [preferredDB, fallbackDB] })
        let index = try XCTUnwrap(lookup.stateIndex(matching: ["desktop-thread", "cli-thread"]))

        XCTAssertEqual(index.existingThreadIDs, ["desktop-thread"])
        XCTAssertEqual(index.archivedThreadIDs, ["desktop-thread"])
        XCTAssertEqual(index.projectNamesByThreadID["desktop-thread"], "cctop")
        XCTAssertEqual(index.unknownThreadIDs, ["cli-thread"])
        XCTAssertEqual(lookup.existingThreadIDs(matching: ["desktop-thread"]), ["desktop-thread"])
        XCTAssertNil(lookup.existingThreadIDs(matching: ["cli-thread"]))
    }

    func testCodexThreadLookupReusesResolvedDatabaseCandidatesAcrossMetadataLookups() {
        let missing = NSTemporaryDirectory() + "cctop-codex-missing-db-\(UUID().uuidString)/state_5.sqlite"
        var resolveCount = 0
        let lookup = CodexThreadArchiveLookup(stateDatabasePaths: {
            resolveCount += 1
            return [missing]
        })
        let threadIDs: Set<String> = ["target-thread"]

        XCTAssertEqual(lookup.projectNames(matching: threadIDs), [:])
        XCTAssertEqual(lookup.archivedThreadIDs(matching: threadIDs), [])
        XCTAssertNil(lookup.existingThreadIDs(matching: threadIDs))
        XCTAssertEqual(lookup.subagentThreadIDs(matching: threadIDs), [])
        XCTAssertEqual(lookup.execHelperThreadIDs(matching: threadIDs), [])
        XCTAssertEqual(resolveCount, 1)
    }

    func testArchivedThreadIDsTreatsArchivedRolloutPlacementAsAuthoritativeWhenSQLiteIsActive() throws {
        let fixture = try makeCodexArchivePlacementFixture(rootPrefix: "cctop-codex-archive-placement")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try writeCodexThreadState(fixture, sqliteArchived: false, rolloutPlacement: .active)
        try writeCodexRollout(.archived, in: fixture)

        XCTAssertEqual(
            archivedThreadIDs(CodexThreadArchiveLookup(stateDatabasePath: fixture.stateDB), in: fixture),
            [fixture.threadID]
        )
    }

    func testArchivedThreadIDsTreatsActiveRolloutPlacementAsAuthoritativeWhenSQLiteIsArchived() throws {
        let fixture = try makeCodexArchivePlacementFixture(rootPrefix: "cctop-codex-active-placement")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try writeCodexThreadState(fixture, sqliteArchived: true, rolloutPlacement: .archived)
        try writeCodexRollout(.active, in: fixture)

        XCTAssertEqual(
            archivedThreadIDs(CodexThreadArchiveLookup(stateDatabasePath: fixture.stateDB), in: fixture),
            []
        )
    }

    func testExecHelperThreadIDsUsesPlacedActiveSiblingWhenSQLiteRolloutPathIsArchived() throws {
        let fixture = try makeCodexArchivePlacementFixture(rootPrefix: "cctop-codex-exec-helper-placement")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try writeCodexThreadState(fixture, sqliteArchived: true, rolloutPlacement: .archived)
        try executeSQLite(
            """
            UPDATE threads
            SET source = 'exec',
                has_user_event = 0,
                first_user_message = 'Review the release diff'
            WHERE id = \(sqlValue(fixture.threadID));
            """,
            path: fixture.stateDB
        )
        try writeCodexRollout(.active, in: fixture)

        XCTAssertEqual(
            CodexThreadArchiveLookup(stateDatabasePath: fixture.stateDB).execHelperThreadIDs(matching: [fixture.threadID]),
            [fixture.threadID]
        )
    }

    func testArchivePlacementStateCarriesFingerprintsUsedForDecision() throws {
        let fixture = try makeCodexArchivePlacementFixture(rootPrefix: "cctop-codex-placement-fingerprint")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try writeCodexRollout(.archived, in: fixture)

        let state = CodexThreadArchiveLookup.archiveState(
            sqliteArchived: false,
            rolloutPath: fixture.activePath
        )

        XCTAssertEqual(state.isArchived, true)
        XCTAssertNil(state.observedFingerprints[fixture.activePath]?.file)
        XCTAssertNotNil(state.observedFingerprints[fixture.archivedPath]?.file)
    }

    func testCodexThreadLookupDerivesProjectNameFromGitOriginURL() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-project-name-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try writeCodexStateDatabase(
            path: stateDB,
            archivedThreads: [],
            gitOrigins: ["codex-desktop-project": "git@github.com:st0012/cctop.git"]
        )

        XCTAssertEqual(
            CodexThreadArchiveLookup(stateDatabasePath: stateDB)
                .projectNames(matching: ["codex-desktop-project"]),
            ["codex-desktop-project": "cctop"]
        )
    }

    func testCodexThreadLookupFallsBackToCwdBasename() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-project-name-cwd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try writeCodexStateDatabase(
            path: stateDB,
            archivedThreads: [],
            cwds: ["codex-desktop-project": "/Users/dev/projects/local-tool"]
        )

        XCTAssertEqual(
            CodexThreadArchiveLookup(stateDatabasePath: stateDB)
                .projectNames(matching: ["codex-desktop-project"]),
            ["codex-desktop-project": "local-tool"]
        )
    }

    func testCodexThreadLookupToleratesMissingExecHelperColumns() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-legacy-columns-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try executeSQLite(
            """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                archived INTEGER NOT NULL DEFAULT 0,
                thread_source TEXT,
                git_origin_url TEXT,
                cwd TEXT
            );
            INSERT INTO threads (id, archived, thread_source, git_origin_url, cwd)
            VALUES ('archived-thread', 1, 'user', NULL, NULL);
            INSERT INTO threads (id, archived, thread_source, git_origin_url, cwd)
            VALUES ('subagent-thread', 0, 'subagent', NULL, NULL);
            INSERT INTO threads (id, archived, thread_source, git_origin_url, cwd)
            VALUES ('project-thread', 0, 'user', 'git@github.com:st0012/cctop.git', NULL);
            """,
            path: stateDB
        )

        let lookup = CodexThreadArchiveLookup(stateDatabasePath: stateDB)
        let threadIDs: Set<String> = ["archived-thread", "subagent-thread", "project-thread"]

        XCTAssertEqual(lookup.existingThreadIDs(matching: threadIDs), threadIDs)
        XCTAssertEqual(lookup.archivedThreadIDs(matching: threadIDs), ["archived-thread"])
        XCTAssertEqual(lookup.subagentThreadIDs(matching: threadIDs), ["subagent-thread"])
        XCTAssertEqual(lookup.execHelperThreadIDs(matching: threadIDs), [])
        XCTAssertEqual(lookup.projectNames(matching: threadIDs), ["project-thread": "cctop"])
    }

    func testCodexThreadLookupInvalidatesCacheWhenSQLiteSidecarChanges() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-wal-cache-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try writeCodexStateDatabase(path: stateDB, archivedThreads: [])
        try executeSQLite(
            """
            INSERT INTO threads (id, rollout_path, archived, thread_source, git_origin_url, cwd, source, has_user_event, first_user_message)
            VALUES ('sidecar-thread', '', 0, 'user', NULL, NULL, 'vscode', 1, '');
            """,
            path: stateDB
        )

        let lookup = CodexThreadArchiveLookup(stateDatabasePath: stateDB)
        XCTAssertEqual(lookup.archivedThreadIDs(matching: ["sidecar-thread"]), [])

        var originalStat = stat()
        XCTAssertEqual(stateDB.withCString { lstat($0, &originalStat) }, 0)

        try executeSQLite("UPDATE threads SET archived = 1 WHERE id = 'sidecar-thread';", path: stateDB)
        var restoredTimes = [
            originalStat.st_atimespec,
            originalStat.st_mtimespec
        ]
        XCTAssertEqual(stateDB.withCString { utimensat(AT_FDCWD, $0, &restoredTimes, 0) }, 0)
        var restoredStat = stat()
        XCTAssertEqual(stateDB.withCString { lstat($0, &restoredStat) }, 0)
        XCTAssertEqual(restoredStat.st_size, originalStat.st_size)
        XCTAssertEqual(restoredStat.st_mtimespec.tv_sec, originalStat.st_mtimespec.tv_sec)
        XCTAssertEqual(restoredStat.st_mtimespec.tv_nsec, originalStat.st_mtimespec.tv_nsec)
        try Data("sidecar changed".utf8).write(to: URL(fileURLWithPath: stateDB + "-wal"))

        XCTAssertEqual(lookup.archivedThreadIDs(matching: ["sidecar-thread"]), ["sidecar-thread"])
    }
}
