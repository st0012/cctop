import XCTest
@testable import CctopMenubar

final class WorktreeCleanupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCandidateGroupingChoosesLatestEndedSessionPerPath() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let old = historySession(
            id: "old",
            path: path,
            name: "Old billing session",
            endedAt: now.addingTimeInterval(-7_200)
        )
        let latest = historySession(
            id: "new",
            path: path,
            name: "Generate invoice retry path",
            endedAt: now
        )

        let candidates = scanner(
            existingPaths: [path],
            inspections: [path: cleanInspection()]
        ).candidates(from: [old, latest], activeProjectPaths: [])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].sessionName, "Generate invoice retry path")
        XCTAssertEqual(candidates[0].lastActiveAt, now)
    }

    func testActiveProjectPathIsIgnored() {
        let path = "/Users/dev/.codex/worktrees/billing-api"

        let candidates = scanner(
            existingPaths: [path],
            inspections: [path: cleanInspection()]
        ).candidates(
            from: [historySession(path: path)],
            activeProjectPaths: [path]
        )

        XCTAssertEqual(candidates[0].state, .ignored(["Active cctop session is using this path"]))
    }

    func testActiveProjectPathDescendantIsIgnored() {
        let path = "/Users/dev/.codex/worktrees/billing-api"

        let candidates = scanner(
            existingPaths: [path],
            inspections: [path: cleanInspection()]
        ).candidates(
            from: [historySession(path: path)],
            activeProjectPaths: ["/Users/dev/.codex/worktrees/billing-api/pkg"]
        )

        XCTAssertEqual(candidates[0].state, .ignored(["Active cctop session is using this path"]))
    }

    func testActiveProjectPathResolvingToCandidateRootIsIgnored() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let aliasPath = "/tmp/billing-api-link"

        let candidates = scanner(
            existingPaths: [path, aliasPath],
            inspections: [path: cleanInspection()],
            resolvedRoots: [aliasPath: path]
        ).candidates(
            from: [historySession(path: path)],
            activeProjectPaths: [aliasPath]
        )

        XCTAssertEqual(candidates[0].state, .ignored(["Active cctop session is using this path"]))
    }

    func testScannerDoesNotResolveUnrelatedActiveProjectPaths() {
        let candidatePath = "/Users/dev/.codex/worktrees/billing-api"
        let activeDocumentsPath = "/Users/dev/Documents/Codex/unrelated-active"
        var resolvedPaths: [String] = []
        let scanner = WorktreeCleanupScanner(
            fileExists: { path in
                path == candidatePath || path == activeDocumentsPath
            },
            resolveWorktreeRoot: { path in
                resolvedPaths.append(path)
                return path == candidatePath ? candidatePath : nil
            },
            inspectGit: { path in
                path == candidatePath ? self.cleanInspection() : GitWorktreeInspection(
                    isRegisteredWorktree: false,
                    isLinkedWorktree: false,
                    isLocked: false,
                    mainWorktreePath: nil,
                    branchName: nil,
                    statusEntries: nil,
                    uniqueCommitCount: nil,
                    failureReasons: ["unexpected inspection"]
                )
            },
            measureSize: { path in
                path == candidatePath ? 1_024 : nil
            }
        )

        let candidates = scanner.candidates(
            from: [historySession(path: candidatePath)],
            activeProjectPaths: [activeDocumentsPath]
        )

        XCTAssertEqual(candidates.map(\.id), [candidatePath])
        XCTAssertEqual(candidates[0].state, .clean)
        XCTAssertEqual(resolvedPaths, [candidatePath])
    }

    func testScannerSkipsProtectedEndedProjectPathWithoutFileProbes() {
        let documentsProjectPath = "/Users/dev/Documents/Codex/old-session"
        var probedPaths: [String] = []
        var resolvedPaths: [String] = []
        var inspectedPaths: [String] = []

        let scanner = WorktreeCleanupScanner(
            fileExists: { path in
                probedPaths.append(path)
                return true
            },
            resolveWorktreeRoot: { path in
                resolvedPaths.append(path)
                return nil
            },
            inspectGit: { path in
                inspectedPaths.append(path)
                return self.cleanInspection()
            },
            measureSize: { _ in 1_024 }
        )

        let candidates = scanner.candidates(
            from: [historySession(path: documentsProjectPath)],
            activeProjectPaths: []
        )

        XCTAssertEqual(candidates, [])
        XCTAssertEqual(probedPaths, [])
        XCTAssertEqual(resolvedPaths, [])
        XCTAssertEqual(inspectedPaths, [])
    }

    func testScannerStillScansProtectedEndedWorktreePath() {
        let documentsWorktreePath = "/Users/dev/Documents/app/.claude/worktrees/feature-x"
        var probedPaths: [String] = []
        var resolvedPaths: [String] = []
        var inspectedPaths: [String] = []

        let scanner = WorktreeCleanupScanner(
            fileExists: { path in
                probedPaths.append(path)
                return path == documentsWorktreePath
            },
            resolveWorktreeRoot: { path in
                resolvedPaths.append(path)
                return path == documentsWorktreePath ? documentsWorktreePath : nil
            },
            inspectGit: { path in
                inspectedPaths.append(path)
                return self.cleanInspection(branch: "claude/feature-x")
            },
            measureSize: { _ in 1_024 }
        )

        let candidates = scanner.candidates(
            from: [historySession(path: documentsWorktreePath)],
            activeProjectPaths: []
        )

        XCTAssertEqual(candidates.map(\.id), [documentsWorktreePath])
        XCTAssertEqual(candidates[0].branchName, "claude/feature-x")
        XCTAssertFalse(probedPaths.isEmpty)
        XCTAssertEqual(resolvedPaths, [documentsWorktreePath])
        XCTAssertEqual(inspectedPaths, [documentsWorktreePath])
    }

    func testActiveProjectPathPrefixSiblingDoesNotProtectCandidate() {
        let path = "/Users/dev/.codex/worktrees/billing-api"

        let candidates = scanner(
            existingPaths: [path],
            inspections: [path: cleanInspection()]
        ).candidates(
            from: [historySession(path: path)],
            activeProjectPaths: ["/Users/dev/.codex/worktrees/billing-api-next"]
        )

        XCTAssertEqual(candidates[0].state, .clean)
    }

    func testMissingPathIsIgnored() {
        let path = "/Users/dev/.codex/worktrees/missing"

        let candidates = scanner(existingPaths: [])
            .candidates(from: [historySession(path: path)], activeProjectPaths: [])

        XCTAssertEqual(candidates[0].state, .ignored(["Path no longer exists"]))
    }

    func testNonWorktreePathIsIgnored() {
        let path = "/Users/dev/projects/cctop"
        let inspection = GitWorktreeInspection(
            isRegisteredWorktree: true,
            isLinkedWorktree: false,
            isLocked: false,
            mainWorktreePath: path,
            branchName: "master",
            statusEntries: [],
            uniqueCommitCount: 0,
            failureReasons: []
        )

        let candidates = scanner(
            existingPaths: [path],
            inspections: [path: inspection]
        ).candidates(from: [historySession(path: path)], activeProjectPaths: [])

        XCTAssertEqual(candidates[0].state, .ignored(["Path is the main checkout, not a linked worktree"]))
    }

    func testDirtyTrackedStatusProducesReview() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let inspection = cleanInspection(statusEntries: [" M Sources/App.swift"])

        let candidate = scanner(
            existingPaths: [path],
            inspections: [path: inspection]
        ).candidates(from: [historySession(path: path)], activeProjectPaths: [])[0]

        XCTAssertEqual(candidate.state, .review(["Worktree has uncommitted tracked changes"]))
    }

    func testIndexHiddenTrackedFilesProduceReview() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let inspection = cleanInspection(failureReasons: [WorktreeCleanupCandidate.indexHiddenTrackedFilesReason])

        let candidate = scanner(
            existingPaths: [path],
            inspections: [path: inspection]
        ).candidates(from: [historySession(path: path)], activeProjectPaths: [])[0]

        XCTAssertEqual(candidate.state, .review([WorktreeCleanupCandidate.indexHiddenTrackedFilesReason]))
        XCTAssertTrue(candidate.checks.contains(WorktreeCleanupCheck(label: "No index-hidden tracked files", status: .review)))
    }

    func testUntrackedFilesProduceReview() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let inspection = cleanInspection(statusEntries: ["?? scratch.txt"])

        let candidate = scanner(
            existingPaths: [path],
            inspections: [path: inspection]
        ).candidates(from: [historySession(path: path)], activeProjectPaths: [])[0]

        XCTAssertEqual(candidate.state, .review(["Worktree has untracked files"]))
    }

    func testIgnoredOnlyStatusProducesReviewWithPreview() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let inspection = cleanInspection(statusEntries: [
            "!! .env.local",
            "!! build/output.o",
            "!! tmp/cache.db",
            "!! secrets.json",
        ])

        let candidate = scanner(
            existingPaths: [path],
            inspections: [path: inspection]
        ).candidates(from: [historySession(path: path)], activeProjectPaths: [])[0]

        XCTAssertEqual(candidate.state, .review([WorktreeCleanupCandidate.ignoredFilesReason]))
        XCTAssertTrue(candidate.checks.contains(WorktreeCleanupCheck(label: "No ignored files", status: .review)))
        let preview = candidate.reviewEvidence.ignoredPreview
        XCTAssertEqual(preview?.items, [".env.local", "build/", "tmp/"])
        XCTAssertEqual(preview?.totalCount, 4)
        XCTAssertEqual(preview?.remainingCount, 1)
    }

    func testUntrackedPreviewCapsItemsAndCountsRemaining() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let inspection = cleanInspection(statusEntries: [
            "?? foo.rb",
            "?? bar baz.rb",
            "?? generated/output.json",
            "?? notes.md",
            "?? nested/more.txt",
        ])

        let candidate = scanner(
            existingPaths: [path],
            inspections: [path: inspection]
        ).candidates(from: [historySession(path: path)], activeProjectPaths: [])[0]

        let preview = candidate.reviewEvidence.untrackedPreview
        XCTAssertEqual(preview?.items, ["foo.rb", "bar baz.rb", "generated/"])
        XCTAssertEqual(preview?.totalCount, 5)
        XCTAssertEqual(preview?.remainingCount, 2)
    }

    func testUntrackedPreviewDecisionEvidenceTextIncludesRemainingCount() throws {
        let preview = try XCTUnwrap(WorktreeCleanupUntrackedPreview(paths: [
            "foo.rb",
            "bar.rb",
            "something/",
            "notes with spaces.md",
            "tmp/cache.json",
            "very-long-local-directory-name-for-middle-truncation/output.txt",
        ]))

        XCTAssertEqual(preview.decisionEvidenceText, "foo.rb, bar.rb, something/, and 3 more")
    }

    func testStatusUnavailableDoesNotInventUntrackedPreview() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let inspection = GitWorktreeInspection(
            isRegisteredWorktree: true,
            isLinkedWorktree: true,
            isLocked: false,
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            statusEntries: nil,
            uniqueCommitCount: 0,
            failureReasons: []
        )

        let candidate = scanner(existingPaths: [path], inspections: [path: inspection])
            .candidates(from: [historySession(path: path)], activeProjectPaths: [])[0]

        XCTAssertEqual(candidate.state, .review(["Git status could not be read"]))
        XCTAssertNil(candidate.reviewEvidence.untrackedPreview)
    }

    func testCleanCandidateHasNoReviewEvidence() {
        let path = "/Users/dev/.codex/worktrees/billing-api"

        let candidate = scanner(
            existingPaths: [path],
            inspections: [path: cleanInspection()]
        ).candidates(from: [historySession(path: path)], activeProjectPaths: [])[0]

        XCTAssertEqual(candidate.state, .clean)
        XCTAssertEqual(candidate.reviewEvidence, .empty)
    }

    func testUniqueLocalCommitsProduceReview() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let inspection = cleanInspection(uniqueCommitCount: 2)

        let candidate = scanner(
            existingPaths: [path],
            inspections: [path: inspection]
        ).candidates(from: [historySession(path: path)], activeProjectPaths: [])[0]

        XCTAssertEqual(candidate.state, .review(["Branch has 2 unique local commits"]))
    }

    func testCleanRegisteredWorktreeProducesCleanCandidate() {
        let path = "/Users/dev/.codex/worktrees/billing-api"

        let candidate = scanner(
            existingPaths: [path],
            inspections: [path: cleanInspection()],
            sizes: [path: Int64(842 * 1_024 * 1_024)]
        ).candidates(from: [historySession(path: path)], activeProjectPaths: [])[0]

        XCTAssertEqual(candidate.state, WorktreeCleanupCandidate.State.clean)
        XCTAssertEqual(candidate.branchName, "feature/invoices")
        XCTAssertEqual(candidate.storageBytes, 842 * 1_024 * 1_024)
    }

    func testEndedSessionSubdirectoryUsesRegisteredWorktreeRoot() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let sessionPath = "/Users/dev/.codex/worktrees/billing-api/pkg"

        let candidates = scanner(
            existingPaths: [worktreePath, sessionPath],
            inspections: [worktreePath: cleanInspection()],
            resolvedRoots: [sessionPath: worktreePath],
            sizes: [worktreePath: 2_048]
        ).candidates(from: [historySession(path: sessionPath)], activeProjectPaths: [])

        XCTAssertEqual(candidates.map(\.id), [worktreePath])
        XCTAssertEqual(candidates[0].worktreePath, worktreePath)
        XCTAssertEqual(candidates[0].worktreeName, "billing-api")
        XCTAssertEqual(candidates[0].sessionName, "Generate invoice retry path")
        XCTAssertEqual(candidates[0].state, .clean)
    }

    func testEndedSessionSubdirectoriesGroupByRegisteredWorktreeRoot() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let olderPath = "/Users/dev/.codex/worktrees/billing-api/pkg"
        let newerPath = "/Users/dev/.codex/worktrees/billing-api/tests"
        let older = historySession(
            id: "older",
            path: olderPath,
            name: "Older subdirectory run",
            endedAt: now.addingTimeInterval(-7_200)
        )
        let newer = historySession(
            id: "newer",
            path: newerPath,
            name: "Latest subdirectory run",
            endedAt: now
        )

        let candidates = scanner(
            existingPaths: [worktreePath, olderPath, newerPath],
            inspections: [worktreePath: cleanInspection()],
            resolvedRoots: [
                olderPath: worktreePath,
                newerPath: worktreePath,
            ]
        ).candidates(from: [older, newer], activeProjectPaths: [])

        XCTAssertEqual(candidates.map(\.id), [worktreePath])
        XCTAssertEqual(candidates[0].sessionName, "Latest subdirectory run")
        XCTAssertEqual(candidates[0].lastActiveAt, now)
    }

    func testEndedSessionDeletedSubdirectoryUsesNearestExistingWorktreeRoot() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let deletedPath = "/Users/dev/.codex/worktrees/billing-api/pkg/generated"

        let candidates = scanner(
            existingPaths: [worktreePath],
            inspections: [worktreePath: cleanInspection()],
            resolvedRoots: [worktreePath: worktreePath],
            sizes: [worktreePath: 2_048]
        ).candidates(from: [historySession(path: deletedPath)], activeProjectPaths: [])

        XCTAssertEqual(candidates.map(\.id), [worktreePath])
        XCTAssertEqual(candidates[0].worktreePath, worktreePath)
        XCTAssertEqual(candidates[0].state, .clean)
    }

    func testStorageFailureKeepsOtherwiseSafeCandidateClean() {
        let path = "/Users/dev/.codex/worktrees/billing-api"

        let candidate = scanner(
            existingPaths: [path],
            inspections: [path: cleanInspection()],
            sizes: [:]
        ).candidates(from: [historySession(path: path)], activeProjectPaths: [])[0]

        XCTAssertEqual(candidate.state, .clean)
        XCTAssertNil(candidate.storageBytes)
        XCTAssertEqual(candidate.formattedStorage, "Unknown")
        XCTAssertEqual(candidate.checks.last, WorktreeCleanupCheck(label: "Storage size scan completed", status: .ignored))
    }

    func testLockedWorktreeProducesReview() {
        let path = "/Users/dev/.codex/worktrees/billing-api"

        let candidate = scanner(
            existingPaths: [path],
            inspections: [path: cleanInspection(isLocked: true)]
        ).candidates(from: [historySession(path: path)], activeProjectPaths: [])[0]

        XCTAssertEqual(candidate.state, .review(["Worktree is locked"]))
        XCTAssertTrue(candidate.checks.contains(WorktreeCleanupCheck(label: "Worktree is not locked", status: .review)))
    }

    func testMissingStatusMarksStatusChecksForReview() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let inspection = GitWorktreeInspection(
            isRegisteredWorktree: true,
            isLinkedWorktree: true,
            isLocked: false,
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            statusEntries: nil,
            uniqueCommitCount: 0,
            failureReasons: []
        )

        let candidate = scanner(existingPaths: [path], inspections: [path: inspection])
            .candidates(from: [historySession(path: path)], activeProjectPaths: [])[0]

        XCTAssertEqual(candidate.state, .review(["Git status could not be read"]))
        XCTAssertEqual(
            candidate.checks.filter {
                $0.label == "No uncommitted tracked changes"
                    || $0.label == "No untracked files"
                    || $0.label == "No ignored files"
            }
                .map(\.status),
            [.review, .review, .review]
        )
    }

    func testInspectorReadsZPorcelainStatusWithAllUntrackedAndIgnoredFiles() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        var statusArguments: [String]?
        let inspector = GitWorktreeInspector { _, arguments in
            switch arguments {
            case ["worktree", "list", "--porcelain", "-z"]:
                return GitCommandResult(
                    exitCode: 0,
                    stdout: "worktree /Users/dev/projects/billing-api\0"
                        + "branch refs/heads/main\0\0"
                        + "worktree \(path)\0"
                        + "branch refs/heads/feature/invoices\0\0",
                    stderr: ""
                )
            case ["branch", "--show-current"]:
                return GitCommandResult(exitCode: 0, stdout: "feature/invoices\n", stderr: "")
            case ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=traditional"]:
                statusArguments = arguments
                return GitCommandResult(
                    exitCode: 0,
                    stdout: "?? file with spaces.txt\0?? nested/path.txt\0!! .env.local\0 M tracked.swift\0",
                    stderr: ""
                )
            case ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]:
                return GitCommandResult(exitCode: 0, stdout: "origin/feature/invoices\n", stderr: "")
            case ["rev-list", "--count", "@{u}..HEAD"]:
                return GitCommandResult(exitCode: 0, stdout: "0\n", stderr: "")
            default:
                return GitCommandResult(exitCode: 1, stdout: "", stderr: "unexpected \(arguments)")
            }
        }

        let inspection = inspector.inspect(path: path)

        XCTAssertEqual(statusArguments, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=traditional"])
        XCTAssertEqual(
            inspection.statusEntries,
            ["?? file with spaces.txt", "?? nested/path.txt", "!! .env.local", " M tracked.swift"]
        )
    }

    func testInspectorMarksAssumeUnchangedTrackedEditsForReviewWhenStatusIsClean() {
        let inspection = hiddenTrackedEditInspection(indexMarker: "h", worktreeObjectID: "worktree-edited")

        XCTAssertTrue(inspection.statusEntries?.isEmpty == true)
        XCTAssertTrue(inspection.failureReasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason))
    }

    func testInspectorIgnoresCleanAssumeUnchangedTrackedFilesWhenStatusIsClean() {
        let inspection = hiddenTrackedEditInspection(indexMarker: "h")

        XCTAssertTrue(inspection.statusEntries?.isEmpty == true)
        XCTAssertFalse(inspection.failureReasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason))
    }

    func testInspectorMarksAssumeUnchangedTrackedModeChangesForReviewWhenStatusIsClean() {
        let inspection = hiddenTrackedEditInspection(indexMarker: "h", indexMode: "100644", worktreeMode: "100755")

        XCTAssertTrue(inspection.statusEntries?.isEmpty == true)
        XCTAssertTrue(inspection.failureReasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason))
    }

    func testInspectorMarksAssumeUnchangedTrackedDeletionsForReviewWhenStatusIsClean() {
        let inspection = hiddenTrackedEditInspection(indexMarker: "h", worktreeObjectExitCode: 128)

        XCTAssertTrue(inspection.statusEntries?.isEmpty == true)
        XCTAssertTrue(inspection.failureReasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason))
    }

    func testInspectorMarksSkipWorktreeTrackedEditsForReviewWhenStatusIsClean() {
        let inspection = hiddenTrackedEditInspection(indexMarker: "S", worktreeObjectID: "worktree-edited")

        XCTAssertTrue(inspection.statusEntries?.isEmpty == true)
        XCTAssertTrue(inspection.failureReasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason))
    }

    func testInspectorIgnoresCleanSkipWorktreeTrackedFilesWhenStatusIsClean() {
        let inspection = hiddenTrackedEditInspection(indexMarker: "S")

        XCTAssertTrue(inspection.statusEntries?.isEmpty == true)
        XCTAssertFalse(inspection.failureReasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason))
    }

    func testInspectorIgnoresCleanAssumeUnchangedSymlinksWhenStatusIsClean() {
        let inspection = hiddenTrackedEditInspection(
            indexMarker: "h",
            indexMode: "120000",
            indexObjectID: "link-target-object",
            worktreeObjectID: "target-file-object",
            worktreeMode: "120000",
            symlinkDestination: "target.txt",
            symlinkObjectID: "link-target-object"
        )

        XCTAssertTrue(inspection.statusEntries?.isEmpty == true)
        XCTAssertFalse(inspection.failureReasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason))
    }

    func testInspectorMarksAssumeUnchangedSymlinkTargetChangesForReviewWhenStatusIsClean() {
        let inspection = hiddenTrackedEditInspection(
            indexMarker: "h",
            indexMode: "120000",
            indexObjectID: "link-target-object",
            worktreeObjectID: "target-file-object",
            worktreeMode: "120000",
            symlinkDestination: "other.txt",
            symlinkObjectID: "changed-link-object"
        )

        XCTAssertTrue(inspection.statusEntries?.isEmpty == true)
        XCTAssertTrue(inspection.failureReasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason))
    }

    func testInspectorIgnoresSparseCheckoutIndexOnlySkipWorktreeFilesWhenStatusIsClean() {
        let inspection = hiddenTrackedEditInspection(
            indexMarker: "S",
            worktreeObjectExitCode: 128,
            sparseCheckRulesOutput: ""
        )

        XCTAssertTrue(inspection.statusEntries?.isEmpty == true)
        XCTAssertFalse(inspection.failureReasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason))
    }

    func testInspectorBatchesSparseCheckoutChecksForAbsentSkipWorktreeEntriesWhenStatusIsClean() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        var hashObjectArguments: [[String]] = []
        var sparseCheckInputs: [String] = []
        let inspector = GitWorktreeInspector(
            runGit: { _, arguments in
                switch arguments {
                case ["worktree", "list", "--porcelain", "-z"]:
                    return GitCommandResult(
                        exitCode: 0,
                        stdout: "worktree /Users/dev/projects/billing-api\0"
                            + "branch refs/heads/main\0\0"
                            + "worktree \(path)\0"
                            + "branch refs/heads/feature/invoices\0\0",
                        stderr: ""
                    )
                case ["branch", "--show-current"]:
                    return GitCommandResult(exitCode: 0, stdout: "feature/invoices\n", stderr: "")
                case ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=traditional"]:
                    return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
                case ["ls-files", "-s", "-v", "-z"]:
                    return GitCommandResult(
                        exitCode: 0,
                        stdout: "S 100644 index-a 0\ta.txt\0"
                            + "S 100644 index-b 0\tb.txt\0"
                            + "s 100644 index-c 0\tc.txt\0"
                            + "H 100644 clean-id 0\tclean.txt\0",
                        stderr: ""
                    )
                case ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]:
                    return GitCommandResult(exitCode: 0, stdout: "origin/feature/invoices\n", stderr: "")
                case ["rev-list", "--count", "@{u}..HEAD"]:
                    return GitCommandResult(exitCode: 0, stdout: "0\n", stderr: "")
                case ["submodule", "status", "--recursive"]:
                    return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
                case let args where args.first == "hash-object":
                    hashObjectArguments.append(args)
                    return GitCommandResult(exitCode: 128, stdout: "", stderr: "fatal: missing")
                default:
                    return GitCommandResult(exitCode: 1, stdout: "", stderr: "unexpected \(arguments)")
                }
            },
            runGitWithInput: { _, arguments, input in
                switch arguments {
                case ["sparse-checkout", "check-rules", "-z"]:
                    sparseCheckInputs.append(input)
                    return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
                default:
                    return GitCommandResult(exitCode: 1, stdout: "", stderr: "unexpected \(arguments)")
                }
            },
            worktreeFileMode: { _ in nil },
            symlinkDestination: { _ in nil }
        )

        let inspection = inspector.inspect(path: path)

        XCTAssertFalse(inspection.failureReasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason))
        XCTAssertEqual(hashObjectArguments, [])
        XCTAssertEqual(sparseCheckInputs, ["a.txt\0b.txt\0c.txt\0"])
    }

    func testInspectorMarksSkipWorktreeTrackedModeChangesForReviewWhenStatusIsClean() {
        let inspection = hiddenTrackedEditInspection(indexMarker: "S", indexMode: "100644", worktreeMode: "100755")

        XCTAssertTrue(inspection.statusEntries?.isEmpty == true)
        XCTAssertTrue(inspection.failureReasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason))
    }

    func testInspectorMarksSparseCheckoutIncludedSkipWorktreeDeletionsForReviewWhenStatusIsClean() {
        let inspection = hiddenTrackedEditInspection(
            indexMarker: "S",
            worktreeObjectExitCode: 128,
            sparseCheckRulesOutput: "tracked.txt\0"
        )

        XCTAssertTrue(inspection.statusEntries?.isEmpty == true)
        XCTAssertTrue(inspection.failureReasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason))
    }

    func testInspectorMarksSkipWorktreeTrackedDeletionsForReviewWhenStatusIsClean() {
        let inspection = hiddenTrackedEditInspection(indexMarker: "S", worktreeObjectExitCode: 128)

        XCTAssertTrue(inspection.statusEntries?.isEmpty == true)
        XCTAssertTrue(inspection.failureReasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason))
    }

    func testInspectorMarksCombinedHiddenTrackedEditsForReviewWhenStatusIsClean() {
        let inspection = hiddenTrackedEditInspection(indexMarker: "s", worktreeObjectID: "worktree-edited")

        XCTAssertTrue(inspection.statusEntries?.isEmpty == true)
        XCTAssertTrue(inspection.failureReasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason))
    }

    func testInspectorMarksInitializedSubmodulesForReview() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let inspector = GitWorktreeInspector { _, arguments in
            switch arguments {
            case ["worktree", "list", "--porcelain", "-z"]:
                return GitCommandResult(
                    exitCode: 0,
                    stdout: "worktree /Users/dev/projects/billing-api\0"
                        + "branch refs/heads/main\0\0"
                        + "worktree \(path)\0"
                        + "branch refs/heads/feature/invoices\0\0",
                    stderr: ""
                )
            case ["branch", "--show-current"]:
                return GitCommandResult(exitCode: 0, stdout: "feature/invoices\n", stderr: "")
            case ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=traditional"]:
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            case ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]:
                return GitCommandResult(exitCode: 0, stdout: "origin/feature/invoices\n", stderr: "")
            case ["rev-list", "--count", "@{u}..HEAD"]:
                return GitCommandResult(exitCode: 0, stdout: "0\n", stderr: "")
            case ["submodule", "status", "--recursive"]:
                return GitCommandResult(exitCode: 0, stdout: " abc123 deps/sub (heads/main)\n", stderr: "")
            default:
                return GitCommandResult(exitCode: 1, stdout: "", stderr: "unexpected \(arguments)")
            }
        }

        let inspection = inspector.inspect(path: path)

        XCTAssertEqual(inspection.failureReasons, [WorktreeCleanupCandidate.initializedSubmodulesReason])
    }

    func testInspectorReadsZPorcelainWorktreeListLockedMetadata() {
        let entries = GitWorktreeInspector.parseWorktreeList(
            "worktree /Users/dev/projects/billing-api\0"
                + "branch refs/heads/main\0\0"
                + "worktree /Users/dev/.codex/worktrees/billing-api\0"
                + "branch refs/heads/feature/invoices\0"
                + "locked maintenance reason\0\0"
        )

        XCTAssertEqual(entries, [
            worktreeEntry("/Users/dev/projects/billing-api", branch: "main"),
            worktreeEntry("/Users/dev/.codex/worktrees/billing-api", branch: "feature/invoices", isLocked: true),
        ])
    }

    func testZStatusParserPreservesPathsAndClassifiesUntrackedIgnoredAndTrackedEntries() {
        let entries = GitWorktreeInspector.parseStatusEntries(
            "?? foo bar.rb\0"
                + "?? nested/path with spaces.txt\0"
                + "!! .env.local\0"
                + "R  renamed new.swift\0renamed old.swift\0"
                + "C  copied new.swift\0copied old.swift\0"
                + " M Sources/App.swift\0"
        )

        XCTAssertEqual(entries, [
            "?? foo bar.rb",
            "?? nested/path with spaces.txt",
            "!! .env.local",
            "R  renamed new.swift",
            "renamed old.swift",
            "C  copied new.swift",
            "copied old.swift",
            " M Sources/App.swift",
        ])
        XCTAssertEqual(
            WorktreeCleanupScanner.untrackedPaths(fromStatusEntries: entries),
            ["foo bar.rb", "nested/path with spaces.txt"]
        )
        XCTAssertEqual(WorktreeCleanupScanner.ignoredPaths(fromStatusEntries: entries), [".env.local"])
        XCTAssertTrue(WorktreeCleanupScanner.hasTrackedChanges(fromStatusEntries: entries))
    }

    func testUntrackedReviewReasonStaysVisiblePastReasonCap() {
        let review = WorktreeCleanupCandidate(
            id: "/Users/dev/.codex/worktrees/review",
            sessionName: "Needs review",
            worktreePath: "/Users/dev/.codex/worktrees/review",
            worktreeName: "review",
            branchName: "feature/review",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([
                "No upstream branch",
                "Branch unique commits could not be verified",
                "Worktree is locked",
                "Worktree has untracked files",
            ]),
            checks: []
        )

        XCTAssertEqual(review.visibleReviewReasons(limit: 3), [
            "No upstream branch",
            "Branch unique commits could not be verified",
            "Worktree has untracked files",
        ])
        XCTAssertEqual(review.remainingReviewReasonCount(limit: 3), 1)
    }

    func testMissingMainCheckoutPathProducesReview() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let inspection = GitWorktreeInspection(
            isRegisteredWorktree: true,
            isLinkedWorktree: true,
            isLocked: false,
            mainWorktreePath: nil,
            branchName: "feature/invoices",
            statusEntries: [],
            uniqueCommitCount: 0,
            failureReasons: []
        )

        let candidate = scanner(existingPaths: [path], inspections: [path: inspection])
            .candidates(from: [historySession(path: path)], activeProjectPaths: [])[0]

        XCTAssertEqual(candidate.state, .review(["Main checkout path could not be verified"]))
    }

    func testInspectorResolvesContainingWorktreeRoot() {
        let repo = "/Users/dev/projects/billing-api"
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let sessionPath = "/Users/dev/.codex/worktrees/billing-api/pkg"
        var arguments: [String]?
        let output = [
            "worktree \(repo)",
            "branch refs/heads/master",
            "",
            "worktree \(worktreePath)",
            "branch refs/heads/feature/invoices",
            "",
        ].joined(separator: "\u{0}")
        let inspector = GitWorktreeInspector(runGit: { path, args in
            arguments = [path] + args
            return GitCommandResult(exitCode: 0, stdout: output, stderr: "")
        })

        XCTAssertEqual(inspector.worktreeRoot(containing: sessionPath), worktreePath)
        XCTAssertEqual(arguments, [sessionPath, "worktree", "list", "--porcelain", "-z"])
    }

    func testInspectorResolvesSymlinkedPathToContainingWorktreeRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cctop-worktree-inspector-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        let worktree = root.appendingPathComponent("worktree")
        let nested = worktree.appendingPathComponent("pkg")
        let symlink = root.appendingPathComponent("worktree-link")
        let symlinkedNestedPath = symlink.appendingPathComponent("pkg").path

        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: worktree)
        defer { try? FileManager.default.removeItem(at: root) }

        let output = [
            "worktree \(repo.path)",
            "branch refs/heads/master",
            "",
            "worktree \(worktree.path)",
            "branch refs/heads/feature/invoices",
            "",
        ].joined(separator: "\u{0}")
        let inspector = GitWorktreeInspector(runGit: { _, _ in
            GitCommandResult(exitCode: 0, stdout: output, stderr: "")
        })

        XCTAssertEqual(inspector.worktreeRoot(containing: symlinkedNestedPath), worktree.path)
    }

    func testRegisteredSiblingWithoutEndedSessionIsNotAdded() {
        let repo = "/Users/dev/projects/billing-api"
        let historyPath = "/Users/dev/projects/billing-api/.claude/worktrees/old-session"
        let siblingPath = "/Users/dev/projects/billing-api/.claude/worktrees/sibling-session"

        let candidates = scanner(
            existingPaths: [repo, historyPath, siblingPath],
            inspections: [
                historyPath: cleanInspection(branch: "claude/old-session"),
                siblingPath: cleanInspection(branch: "claude/sibling-session"),
            ],
            sizes: [
                historyPath: 2_048,
                siblingPath: 4_096,
            ]
        ).candidates(from: [historySession(path: historyPath)], activeProjectPaths: [])

        XCTAssertEqual(candidates.map(\.id), [historyPath])
        XCTAssertFalse(candidates.contains { $0.id == siblingPath })
    }

    func testEndedSessionPathUsesNewestMatchingSessionMetadata() {
        let repo = "/Users/dev/projects/billing-api"
        let seedPath = "/Users/dev/projects/billing-api/.claude/worktrees/seed"
        let endedPath = "/Users/dev/projects/billing-api/.claude/worktrees/discovered"
        let older = historySession(
            id: "older",
            path: endedPath,
            name: "Older cleanup name",
            endedAt: now.addingTimeInterval(-7_200)
        )
        let newer = historySession(
            id: "newer",
            path: endedPath,
            name: "Review invoice cleanup",
            endedAt: now
        )

        let candidate = scanner(
            existingPaths: [repo, seedPath, endedPath],
            inspections: [
                seedPath: cleanInspection(branch: "claude/seed"),
                endedPath: cleanInspection(branch: "claude/discovered"),
            ]
        ).candidates(from: [historySession(path: seedPath), older, newer], activeProjectPaths: [])
            .first { $0.id == endedPath }

        XCTAssertEqual(candidate?.sessionName, "Review invoice cleanup")
        XCTAssertEqual(candidate?.lastActiveAt, now)
    }

    func testWorktreeDiscoveryDoesNotAddAnySiblingWithoutEndedSession() {
        let repo = "/Users/dev/projects/billing-api"
        let prunablePath = "/Users/dev/projects/billing-api/.claude/worktrees/prunable"
        let linkedPath = "/Users/dev/projects/billing-api/.claude/worktrees/linked"

        let candidates = scanner(
            existingPaths: [repo, prunablePath, linkedPath],
            inspections: [
                repo: GitWorktreeInspection(
                    isRegisteredWorktree: true,
                    isLinkedWorktree: false,
                    isLocked: false,
                    mainWorktreePath: repo,
                    branchName: "master",
                    statusEntries: [],
                    uniqueCommitCount: 0,
                    failureReasons: []
                ),
                linkedPath: cleanInspection(branch: "claude/linked"),
            ],
            sizes: [repo: 1_024]
        ).candidates(from: [historySession(path: repo, branch: "master")], activeProjectPaths: [])

        XCTAssertFalse(candidates.contains { $0.id == prunablePath })
        XCTAssertFalse(candidates.contains { $0.id == linkedPath })
    }

    func testNonEndedSessionPathIsNotCleanupCandidate() {
        let activePath = "/Users/dev/projects/billing-api/.claude/worktrees/active-feature"

        let candidates = scanner(
            existingPaths: [activePath],
            inspections: [activePath: cleanInspection(branch: "claude/active-feature")]
        ).candidates(from: [activeSession(path: activePath)], activeProjectPaths: [])

        XCTAssertTrue(candidates.isEmpty)
    }

    func testSizeFormatterUsesReadableUnits() {
        XCTAssertEqual(WorktreeCleanupCandidate.formatStorage(bytes: nil), "Unknown")
        XCTAssertEqual(WorktreeCleanupCandidate.formatStorage(bytes: 900), "900 B")
        XCTAssertEqual(WorktreeCleanupCandidate.formatStorage(bytes: 900 * 1_024), "900 KB")
        XCTAssertEqual(WorktreeCleanupCandidate.formatStorage(bytes: 842 * 1_024 * 1_024), "842 MB")
        XCTAssertEqual(WorktreeCleanupCandidate.formatStorage(bytes: 1_800_000_000), "1.7 GB")
    }

    func testActionableStateExcludesIgnoredCandidates() {
        XCTAssertTrue(WorktreeCleanupCandidate.State.clean.isActionable)
        XCTAssertTrue(WorktreeCleanupCandidate.State.review(["needs eyes"]).isActionable)
        XCTAssertFalse(WorktreeCleanupCandidate.State.ignored(["main checkout"]).isActionable)
    }

    func testPopupTabAvailabilityAlwaysIncludesCleanupForExplicitScan() {
        XCTAssertEqual(
            PopupTab.availableTabs(hasIdleSessions: false, hasRecentProjects: false, hasCleanupCandidates: false),
            [.active, .cleanup]
        )
        XCTAssertEqual(
            PopupTab.availableTabs(hasIdleSessions: true, hasRecentProjects: true, hasCleanupCandidates: true),
            [.active, .idle, .recent, .cleanup]
        )
    }

    func testKeyboardTabSwitchingIncludesCleanup() {
        let tabs: [PopupTab] = [.active, .recent, .cleanup]

        XCTAssertEqual(PopupTab.switched(from: .recent, action: .nextTab, availableTabs: tabs), .cleanup)
        XCTAssertEqual(PopupTab.switched(from: .cleanup, action: .nextTab, availableTabs: tabs), .active)
        XCTAssertEqual(PopupTab.switched(from: .active, action: .previousTab, availableTabs: tabs), .cleanup)
    }

    func testConfirmingCleanupSelectionTargetsCleanupDetail() {
        let candidate = cleanupCandidate(path: "/Users/dev/.codex/worktrees/billing-api")

        let target = PopupSelectionTarget.target(
            for: .cleanup,
            index: 0,
            in: PopupSelectionContext(
                activeSessions: [],
                idleSessions: [],
                recentProjects: [],
                cleanupCandidates: [candidate]
            )
        )

        XCTAssertEqual(target, .cleanupCandidate(candidate))
    }

    @MainActor
    func testCleanupCandidateChangeNotifiesLayout() async throws {
        let candidate = cleanupCandidate(path: "/Users/dev/.codex/worktrees/billing-api")
        let layoutChanged = expectation(description: "cleanup candidate change notifies layout")
        let view = popupView(
            cleanupCandidates: [candidate],
            onLayoutChanged: { layoutChanged.fulfill() }
        )

        view.handleCleanupCandidatesChanged()

        await fulfillment(of: [layoutChanged], timeout: 1)
    }

    @MainActor
    func testCleanupScanningChangeNotifiesLayout() async throws {
        let layoutChanged = expectation(description: "cleanup scanning change notifies layout")
        let view = popupView(
            cleanupCandidates: [],
            onLayoutChanged: { layoutChanged.fulfill() }
        )

        view.handleCleanupScanningChanged()

        await fulfillment(of: [layoutChanged], timeout: 1)
    }

    @MainActor
    func testCleanupTabBecomingVisibleRequestsFreshCleanupScan() {
        let candidate = cleanupCandidate(path: "/Users/dev/.codex/worktrees/billing-api")
        var visibilityRefreshCount = 0
        let view = popupView(
            cleanupCandidates: [candidate],
            onCleanupTabVisible: { visibilityRefreshCount += 1 }
        )

        view.handleSelectedTabChanged(.cleanup)
        view.handleSelectedTabChanged(.active)

        XCTAssertEqual(visibilityRefreshCount, 1)
    }

    func testCleanupCandidateSyncUpdatesSelectedDetailWhenIDStillExists() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let clean = cleanupCandidate(path: path)
        let review = WorktreeCleanupCandidate(
            id: path,
            sessionName: clean.sessionName,
            worktreePath: clean.worktreePath,
            worktreeName: clean.worktreeName,
            branchName: clean.branchName,
            lastActiveAt: clean.lastActiveAt,
            storageBytes: clean.storageBytes,
            state: .review(["Worktree has untracked files"]),
            checks: []
        )

        XCTAssertEqual(PopupView.syncedCleanupCandidate(clean, in: [review]), review)
    }

    @MainActor
    func testNavigateConfirmingCleanupCandidateKeepsNavigateModeActive() async throws {
        let candidate = cleanupCandidate(path: "/Users/dev/.codex/worktrees/billing-api")
        let target = PopupSelectionTarget.target(
            for: .cleanup,
            index: 0,
            in: PopupSelectionContext(
                activeSessions: [],
                idleSessions: [],
                recentProjects: [],
                cleanupCandidates: [candidate]
            )
        )

        XCTAssertEqual(target, .cleanupCandidate(candidate))
        XCTAssertEqual(target?.confirmsNavigate, false)
    }

    func testRefreshSignatureIsStableForIdenticalInputs() {
        let session = historySession(path: "/Users/dev/.codex/worktrees/billing-api")
        let lhs = WorktreeCleanupRefreshSignature(
            sourceSessions: [session],
            activeProjectPaths: ["/Users/dev/projects/app"]
        )
        let rhs = WorktreeCleanupRefreshSignature(
            sourceSessions: [session],
            activeProjectPaths: ["/Users/dev/projects/app"]
        )

        XCTAssertEqual(lhs, rhs)
    }

    func testRefreshSignatureChangesWhenActivePathsChange() {
        let session = historySession(path: "/Users/dev/.codex/worktrees/billing-api")
        let lhs = WorktreeCleanupRefreshSignature(
            sourceSessions: [session],
            activeProjectPaths: ["/Users/dev/projects/app"]
        )
        let rhs = WorktreeCleanupRefreshSignature(
            sourceSessions: [session],
            activeProjectPaths: ["/Users/dev/projects/other"]
        )

        XCTAssertNotEqual(lhs, rhs)
    }

    func testRefreshSignatureChangesWhenEndedSessionMetadataChangesForSamePath() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let old = historySession(
            id: "old",
            path: path,
            name: "Old billing session",
            branch: "feature/old-invoices",
            endedAt: now.addingTimeInterval(-7_200)
        )
        let newer = historySession(
            id: "new",
            path: path,
            name: "Generate invoice retry path",
            branch: "feature/invoices",
            endedAt: now
        )
        let lhs = WorktreeCleanupRefreshSignature(sourceSessions: [old], activeProjectPaths: [])
        let rhs = WorktreeCleanupRefreshSignature(sourceSessions: [newer], activeProjectPaths: [])

        XCTAssertNotEqual(lhs, rhs)
    }

    @MainActor
    func testNonForcedRefreshRunsWhenLatestEndedSessionForPathChanges() async throws {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let old = historySession(
            id: "old",
            path: path,
            name: "Old billing session",
            branch: "feature/old-invoices",
            endedAt: now.addingTimeInterval(-7_200)
        )
        let newer = historySession(
            id: "new",
            path: path,
            name: "Generate invoice retry path",
            branch: "feature/invoices",
            endedAt: now
        )
        let manager = WorktreeCleanupManager(
            scanner: scanner(
                existingPaths: [path],
                inspections: [path: cleanInspection()],
                sizes: [path: 1_024]
            )
        )

        manager.refresh(from: [old], activeProjectPaths: [])
        try await waitForCleanupCandidates(manager) { candidates in
            candidates.first?.sessionName == "Old billing session"
        }

        manager.refresh(from: [newer], activeProjectPaths: [])
        try await waitForCleanupCandidates(manager) { candidates in
            candidates.first?.sessionName == "Generate invoice retry path"
                && candidates.first?.branchName == "feature/invoices"
                && candidates.first?.lastActiveAt == self.now
        }
    }

    @MainActor
    func testForceRefreshBypassesStableSignature() async throws {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        var inspection = cleanInspection()
        let manager = WorktreeCleanupManager(
            scanner: WorktreeCleanupScanner(
                fileExists: { _ in true },
                resolveWorktreeRoot: { _ in nil },
                inspectGit: { _ in inspection },
                measureSize: { _ in 1_024 }
            )
        )

        manager.refresh(from: [session], activeProjectPaths: [])
        try await waitForCleanupCandidates(manager) { candidates in
            candidates.first?.state == .clean
        }

        inspection = cleanInspection(statusEntries: ["?? scratch.txt"])
        manager.refresh(from: [session], activeProjectPaths: [])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(manager.candidates.first?.state, .clean)

        manager.refresh(from: [session], activeProjectPaths: [], force: true)
        try await waitForCleanupCandidates(manager) { candidates in
            candidates.first?.state == .review(["Worktree has untracked files"])
        }
    }

    @MainActor
    func testRefreshPublishesScanningWhileScanIsBlockedAndClearsAfterCompletion() async throws {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let scanStarted = expectation(description: "scan started")
        let releaseScan = DispatchSemaphore(value: 0)
        let manager = WorktreeCleanupManager(
            scanner: WorktreeCleanupScanner(
                fileExists: { _ in true },
                resolveWorktreeRoot: { _ in nil },
                inspectGit: { _ in
                    scanStarted.fulfill()
                    releaseScan.wait()
                    return self.cleanInspection()
                },
                measureSize: { _ in 1_024 }
            )
        )

        manager.refresh(from: [session], activeProjectPaths: [], force: true)

        XCTAssertTrue(manager.isScanning)
        await fulfillment(of: [scanStarted], timeout: 1)

        releaseScan.signal()
        try await waitForCleanupCandidates(manager) { candidates in
            candidates.first?.id == worktreePath
        }
        XCTAssertFalse(manager.isScanning)
    }

    @MainActor
    func testRefreshKeepsScanningUntilLatestGenerationCompletes() async throws {
        let firstPath = "/Users/dev/.codex/worktrees/first"
        let secondPath = "/Users/dev/.codex/worktrees/second"
        let firstStarted = expectation(description: "first scan started")
        let secondStarted = expectation(description: "second scan started")
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        let manager = WorktreeCleanupManager(
            scanner: WorktreeCleanupScanner(
                fileExists: { _ in true },
                resolveWorktreeRoot: { _ in nil },
                inspectGit: { path in
                    switch path {
                    case firstPath:
                        firstStarted.fulfill()
                        releaseFirst.wait()
                        return self.cleanInspection(branch: "feature/first")
                    case secondPath:
                        secondStarted.fulfill()
                        releaseSecond.wait()
                        return self.cleanInspection(branch: "feature/second")
                    default:
                        return self.cleanInspection()
                    }
                },
                measureSize: { _ in 1_024 }
            )
        )

        manager.refresh(from: [historySession(path: firstPath)], activeProjectPaths: [], force: true)
        await fulfillment(of: [firstStarted], timeout: 1)

        manager.refresh(from: [historySession(path: secondPath)], activeProjectPaths: [], force: true)
        XCTAssertTrue(manager.isScanning)
        await fulfillment(of: [secondStarted], timeout: 1)

        releaseFirst.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(manager.isScanning)

        releaseSecond.signal()
        try await waitForCleanupCandidates(manager) { candidates in
            candidates.first?.id == secondPath
        }
        XCTAssertFalse(manager.isScanning)
    }

    @MainActor
    func testCleanupRefreshGateDoesNotScanWhileCleanupIsHidden() async throws {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        var inspectionCount = 0
        let manager = WorktreeCleanupManager(
            scanner: WorktreeCleanupScanner(
                fileExists: { _ in true },
                resolveWorktreeRoot: { _ in nil },
                inspectGit: { _ in
                    inspectionCount += 1
                    return self.cleanInspection()
                },
                measureSize: { _ in 1_024 }
            )
        )
        let gate = WorktreeCleanupRefreshGate(manager: manager)

        gate.updateSources([session], activeProjectPaths: [])
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(inspectionCount, 0)
        XCTAssertEqual(manager.candidates, [])
    }

    @MainActor
    func testCleanupRefreshGateScansWhenCleanupBecomesVisible() async throws {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        var inspectionCount = 0
        let manager = WorktreeCleanupManager(
            scanner: WorktreeCleanupScanner(
                fileExists: { _ in true },
                resolveWorktreeRoot: { _ in nil },
                inspectGit: { _ in
                    inspectionCount += 1
                    return self.cleanInspection()
                },
                measureSize: { _ in 1_024 }
            )
        )
        let gate = WorktreeCleanupRefreshGate(manager: manager)

        gate.updateSources([session], activeProjectPaths: [])
        gate.setCleanupVisible(true)

        try await waitForCleanupCandidates(manager) { candidates in
            candidates.first?.worktreePath == worktreePath
        }
        XCTAssertEqual(inspectionCount, 1)
    }

    @MainActor
    func testCleanupRefreshGateStopsScanningAfterCleanupIsHidden() async throws {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        var inspection = cleanInspection()
        var inspectionCount = 0
        let manager = WorktreeCleanupManager(
            scanner: WorktreeCleanupScanner(
                fileExists: { _ in true },
                resolveWorktreeRoot: { _ in nil },
                inspectGit: { _ in
                    inspectionCount += 1
                    return inspection
                },
                measureSize: { _ in 1_024 }
            )
        )
        let gate = WorktreeCleanupRefreshGate(manager: manager)

        gate.updateSources([session], activeProjectPaths: [])
        gate.setCleanupVisible(true)
        try await waitForCleanupCandidates(manager) { candidates in
            candidates.first?.state == .clean
        }

        gate.setCleanupVisible(false)
        inspection = cleanInspection(statusEntries: ["?? scratch.txt"])
        gate.updateSources(
            [historySession(id: "new", path: worktreePath, endedAt: now.addingTimeInterval(1))],
            activeProjectPaths: []
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(inspectionCount, 1)
        XCTAssertEqual(manager.candidates.first?.state, .clean)
    }

    func testRemovalServiceRunsGitWorktreeRemoveWithArgumentArrayForCleanCandidate() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let mainPath = "/Users/dev/projects/billing-api"
        let session = historySession(path: worktreePath)
        let candidate = cleanupCandidate(path: worktreePath)
        var gitArguments: [[String]] = []
        let service = WorktreeRemovalService(
            scanner: scanner(existingPaths: [worktreePath], inspections: [worktreePath: cleanInspection()]),
            runGit: { arguments in
                gitArguments.append(arguments)
                return GitCommandResult(exitCode: 0, stdout: "removed\n", stderr: "")
            }
        )

        let result = service.remove(candidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertEqual(gitArguments, [["-C", mainPath, "worktree", "remove", worktreePath]])
        XCTAssertEqual(result, .removed(GitCommandResult(exitCode: 0, stdout: "removed\n", stderr: "")))
    }

    func testRemovalServiceRunsGitWorktreeRemoveWithArgumentArrayForReviewCandidate() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let mainPath = "/Users/dev/projects/billing-api"
        let session = historySession(path: worktreePath)
        let candidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: mainPath,
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review(["Worktree has untracked files"]),
            checks: []
        )
        var gitArguments: [[String]] = []
        let service = WorktreeRemovalService(
            scanner: scanner(existingPaths: [worktreePath], inspections: [worktreePath: cleanInspection()]),
            runGit: { arguments in
                gitArguments.append(arguments)
                return GitCommandResult(exitCode: 0, stdout: "removed\n", stderr: "")
            }
        )

        let result = service.remove(candidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertEqual(gitArguments, [["-C", mainPath, "worktree", "remove", worktreePath]])
        XCTAssertEqual(result, .removed(GitCommandResult(exitCode: 0, stdout: "removed\n", stderr: "")))
    }

    func testRemovalServiceRefusesWhenPreflightWorktreeIdentityChanges() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let staleCleanCandidate = cleanupCandidate(path: worktreePath)
        let recreatedInspection = GitWorktreeInspection(
            isRegisteredWorktree: true,
            isLinkedWorktree: true,
            isLocked: false,
            mainWorktreePath: "/Users/dev/projects/other-main",
            branchName: "feature/other-work",
            statusEntries: [],
            uniqueCommitCount: 0,
            failureReasons: []
        )
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(existingPaths: [worktreePath], inspections: [worktreePath: recreatedInspection]),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "removed\n", stderr: "")
            }
        )

        let result = service.remove(staleCleanCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused when worktree identity changed, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.branchName, "feature/other-work")
    }

    func testRemovalServiceRefusesInitializedSubmoduleCandidateWithoutInvokingGit() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let candidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Submodule cleanup",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([WorktreeCleanupCandidate.initializedSubmodulesReason]),
            checks: []
        )
        let inspection = GitWorktreeInspection(
            isRegisteredWorktree: true,
            isLinkedWorktree: true,
            isLocked: false,
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            statusEntries: [],
            uniqueCommitCount: 0,
            failureReasons: [WorktreeCleanupCandidate.initializedSubmodulesReason]
        )
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(existingPaths: [worktreePath], inspections: [worktreePath: inspection]),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "removed\n", stderr: "")
            }
        )

        let result = service.remove(candidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected initialized-submodule review candidate to be refused, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.state, .review([WorktreeCleanupCandidate.initializedSubmodulesReason]))
    }

    func testRemovalServiceLetsGitRefuseReviewCandidateWithDirtyPreflight() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review(["Worktree has untracked files"]),
            checks: [],
            reviewEvidence: WorktreeCleanupReviewEvidence(
                untrackedPreview: WorktreeCleanupUntrackedPreview(paths: ["scratch.txt"])
            )
        )
        let failure = GitCommandResult(
            exitCode: 128,
            stdout: "",
            stderr: "fatal: contains modified or untracked files\n"
        )
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [worktreePath: cleanInspection(statusEntries: ["?? scratch.txt"])]
            ),
            runGit: { _ in
                didRunGit = true
                return failure
            }
        )

        let result = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertTrue(didRunGit)
        XCTAssertEqual(result, .failed(failure))
    }

    func testRemovalServiceOffersForceAfterDirtyGitFailureWhenFreshEvidenceMatches() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let mainPath = "/Users/dev/projects/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs force review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: mainPath,
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([WorktreeCleanupCandidate.untrackedFilesReason]),
            checks: [],
            reviewEvidence: WorktreeCleanupReviewEvidence(
                untrackedPreview: WorktreeCleanupUntrackedPreview(paths: ["scratch.txt"])
            )
        )
        let failure = GitCommandResult(
            exitCode: 128,
            stdout: "",
            stderr: "fatal: '\(worktreePath)' contains modified or untracked files, use --force to delete it\n"
        )
        var gitArguments: [[String]] = []
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [worktreePath: cleanInspection(statusEntries: ["?? scratch.txt"])]
            ),
            runGit: { arguments in
                gitArguments.append(arguments)
                return failure
            }
        )

        let result = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertEqual(gitArguments, [["-C", mainPath, "worktree", "remove", worktreePath]])
        guard case .forceRequired(let offer) = result else {
            return XCTFail("Expected dirty remove failure to offer force, got \(result)")
        }
        XCTAssertEqual(offer.candidate.reviewEvidence.untrackedPreview?.items, ["scratch.txt"])
        XCTAssertEqual(offer.failure, failure)
    }

    func testRemovalServiceForceRemoveRunsGitForceAfterFreshChecksPass() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let mainPath = "/Users/dev/projects/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs force review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: mainPath,
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([WorktreeCleanupCandidate.untrackedFilesReason]),
            checks: [],
            reviewEvidence: WorktreeCleanupReviewEvidence(
                untrackedPreview: WorktreeCleanupUntrackedPreview(paths: ["scratch.txt"])
            )
        )
        let plainFailure = GitCommandResult(
            exitCode: 128,
            stdout: "",
            stderr: "fatal: '\(worktreePath)' contains modified or untracked files, use --force to delete it\n"
        )
        let forceSuccess = GitCommandResult(exitCode: 0, stdout: "removed\n", stderr: "")
        var gitArguments: [[String]] = []
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [worktreePath: cleanInspection(statusEntries: ["?? scratch.txt"])]
            ),
            runGit: { arguments in
                gitArguments.append(arguments)
                return arguments.contains("--force") ? forceSuccess : plainFailure
            }
        )

        let plainResult = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])
        guard case .forceRequired(let offer) = plainResult else {
            return XCTFail("Expected dirty remove failure to offer force, got \(plainResult)")
        }

        let forceResult = service.forceRemove(offer, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertEqual(gitArguments, [
            ["-C", mainPath, "worktree", "remove", worktreePath],
            ["-C", mainPath, "worktree", "remove", "--force", worktreePath],
        ])
        XCTAssertEqual(forceResult, .removed(forceSuccess))
    }

    func testRemovalServiceDoesNotOfferForceForUnrelatedGitFailure() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([WorktreeCleanupCandidate.untrackedFilesReason]),
            checks: [],
            reviewEvidence: WorktreeCleanupReviewEvidence(
                untrackedPreview: WorktreeCleanupUntrackedPreview(paths: ["scratch.txt"])
            )
        )
        let failure = GitCommandResult(exitCode: 128, stdout: "", stderr: "fatal: worktree is locked\n")
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [worktreePath: cleanInspection(statusEntries: ["?? scratch.txt"])]
            ),
            runGit: { _ in failure }
        )

        let result = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertEqual(result, .failed(failure))
    }

    func testRemovalServiceDoesNotOfferForceWhenHardBlockerAppears() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review(["Branch has 1 unique local commit"]),
            checks: []
        )
        let failure = GitCommandResult(
            exitCode: 128,
            stdout: "",
            stderr: "fatal: '\(worktreePath)' contains modified or untracked files, use --force to delete it\n"
        )
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [worktreePath: cleanInspection(uniqueCommitCount: 1)]
            ),
            runGit: { _ in failure }
        )

        let result = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertEqual(result, .failed(failure))
    }

    func testRemovalServiceRefusesWhenFreshStatusCannotBeRead() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review(["Branch has 1 unique local commit"]),
            checks: []
        )
        var didRunGit = false
        let unreadableStatusInspection = GitWorktreeInspection(
            isRegisteredWorktree: true,
            isLinkedWorktree: true,
            isLocked: false,
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            statusEntries: nil,
            uniqueCommitCount: 1,
            failureReasons: []
        )
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [worktreePath: unreadableStatusInspection]
            ),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "removed\n", stderr: "")
            }
        )

        let result = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected unreadable fresh status to refuse removal, got \(result)")
        }
        XCTAssertTrue(preflightCandidate.state.reasons.contains(WorktreeCleanupCandidate.statusUnreadableReason))
    }

    func testRemovalServiceRefusesForceWhenFreshEvidenceChangesBeforeForce() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let candidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs force review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([WorktreeCleanupCandidate.untrackedFilesReason]),
            checks: [],
            reviewEvidence: WorktreeCleanupReviewEvidence(
                untrackedPreview: WorktreeCleanupUntrackedPreview(paths: ["scratch.txt"])
            )
        )
        let offer = WorktreeForceRemovalOffer(
            candidate: candidate,
            failure: GitCommandResult(
                exitCode: 128,
                stdout: "",
                stderr: "fatal: '\(worktreePath)' contains modified or untracked files, use --force to delete it\n"
            )
        )
        var gitArguments: [[String]] = []
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [worktreePath: cleanInspection(statusEntries: ["?? other.txt"])]
            ),
            runGit: { arguments in
                gitArguments.append(arguments)
                return GitCommandResult(exitCode: 0, stdout: "removed\n", stderr: "")
            }
        )

        let result = service.forceRemove(offer, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertTrue(gitArguments.isEmpty)
        guard case .refused(let latestCandidate) = result else {
            return XCTFail("Expected force removal to refuse changed evidence, got \(result)")
        }
        XCTAssertEqual(latestCandidate.reviewEvidence.untrackedPreview?.items, ["other.txt"])
    }

    func testRemovalServiceRefusesForceWhenTrackedChangesAppearBeforeForce() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let candidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs force review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([WorktreeCleanupCandidate.untrackedFilesReason]),
            checks: [],
            reviewEvidence: WorktreeCleanupReviewEvidence(
                untrackedPreview: WorktreeCleanupUntrackedPreview(paths: ["scratch.txt"])
            )
        )
        let offer = WorktreeForceRemovalOffer(
            candidate: candidate,
            failure: GitCommandResult(
                exitCode: 128,
                stdout: "",
                stderr: "fatal: '\(worktreePath)' contains modified or untracked files, use --force to delete it\n"
            )
        )
        var gitArguments: [[String]] = []
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [worktreePath: cleanInspection(statusEntries: ["?? scratch.txt", " M tracked.swift"])]
            ),
            runGit: { arguments in
                gitArguments.append(arguments)
                return GitCommandResult(exitCode: 0, stdout: "removed\n", stderr: "")
            }
        )

        let result = service.forceRemove(offer, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertTrue(gitArguments.isEmpty)
        guard case .refused(let latestCandidate) = result else {
            return XCTFail("Expected force removal to refuse newly tracked changes, got \(result)")
        }
        XCTAssertTrue(latestCandidate.state.reasons.contains(WorktreeCleanupCandidate.trackedChangesReason))
    }

    func testRemovalServiceKeepsCleanPreflightSafetyWhenCandidateDowngradesToReview() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let staleCleanCandidate = cleanupCandidate(path: worktreePath)
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [worktreePath: cleanInspection(statusEntries: ["?? scratch.txt"])]
            ),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(staleCleanCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused after dirty preflight, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.state, .review(["Worktree has untracked files"]))
    }

    func testRemovalServiceRefusesStaleCleanCandidateWhenIgnoredFilesAppearBeforePreflight() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let staleCleanCandidate = cleanupCandidate(path: worktreePath)
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [worktreePath: cleanInspection(statusEntries: ["!! .env.local"])]
            ),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(staleCleanCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused after ignored-file preflight, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.state, .review([WorktreeCleanupCandidate.ignoredFilesReason]))
        XCTAssertEqual(preflightCandidate.reviewEvidence.ignoredPreview?.items, [".env.local"])
    }

    func testRemovalServiceRefusesStaleCleanCandidateWhenIndexHiddenTrackedFilesAppearBeforePreflight() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let staleCleanCandidate = cleanupCandidate(path: worktreePath)
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [
                    worktreePath: cleanInspection(failureReasons: [WorktreeCleanupCandidate.indexHiddenTrackedFilesReason])
                ]
            ),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(staleCleanCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused after hidden-index tracked files appeared, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.state, .review([WorktreeCleanupCandidate.indexHiddenTrackedFilesReason]))
    }

    func testRemovalServiceRefusesReviewCandidateWhenPreflightAddsIgnoredFiles() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review(["Branch has 1 unique local commit"]),
            checks: []
        )
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [worktreePath: cleanInspection(statusEntries: ["!! .env.local"], uniqueCommitCount: 1)]
            ),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused after ignored-file preflight, got \(result)")
        }
        XCTAssertEqual(
            Set(preflightCandidate.state.reasons),
            Set(["Branch has 1 unique local commit", WorktreeCleanupCandidate.ignoredFilesReason])
        )
        XCTAssertEqual(preflightCandidate.reviewEvidence.ignoredPreview?.items, [".env.local"])
    }

    func testRemovalServiceRefusesReviewCandidateWhenIndexHiddenTrackedFilesAppearBeforePreflight() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([WorktreeCleanupCandidate.untrackedFilesReason]),
            checks: [],
            reviewEvidence: WorktreeCleanupReviewEvidence(
                untrackedPreview: WorktreeCleanupUntrackedPreview(paths: ["scratch.txt"])
            )
        )
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [
                    worktreePath: cleanInspection(
                        statusEntries: ["?? scratch.txt"],
                        failureReasons: [WorktreeCleanupCandidate.indexHiddenTrackedFilesReason]
                    )
                ]
            ),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused after hidden-index tracked files appeared, got \(result)")
        }
        XCTAssertEqual(
            Set(preflightCandidate.state.reasons),
            Set([WorktreeCleanupCandidate.untrackedFilesReason, WorktreeCleanupCandidate.indexHiddenTrackedFilesReason])
        )
    }

    func testRemovalServiceRefusesReviewCandidateWithIndexHiddenTrackedFilesWithoutInvokingGit() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([WorktreeCleanupCandidate.indexHiddenTrackedFilesReason]),
            checks: []
        )
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [
                    worktreePath: cleanInspection(failureReasons: [WorktreeCleanupCandidate.indexHiddenTrackedFilesReason])
                ]
            ),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused for hidden-index tracked files, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.state, .review([WorktreeCleanupCandidate.indexHiddenTrackedFilesReason]))
    }

    func testRemovalServiceRefusesReviewCandidateWhenIgnoredFileEvidenceChanges() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([WorktreeCleanupCandidate.ignoredFilesReason]),
            checks: [],
            reviewEvidence: WorktreeCleanupReviewEvidence(
                ignoredPreview: WorktreeCleanupUntrackedPreview(paths: ["cache/"])
            )
        )
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [worktreePath: cleanInspection(statusEntries: ["!! .env.local"])]
            ),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused after ignored-file evidence changed, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.state, .review([WorktreeCleanupCandidate.ignoredFilesReason]))
        XCTAssertEqual(preflightCandidate.reviewEvidence.ignoredPreview?.items, [".env.local"])
    }

    func testRemovalServiceRefusesWhenFinalInspectionAddsIgnoredEvidence() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let staleCleanCandidate = cleanupCandidate(path: worktreePath)
        var didRunGit = false
        var inspectionCount = 0
        let service = WorktreeRemovalService(
            scanner: WorktreeCleanupScanner(
                fileExists: { $0 == worktreePath },
                resolveWorktreeRoot: { _ in nil },
                inspectGit: { _ in
                    inspectionCount += 1
                    if inspectionCount == 1 {
                        return self.cleanInspection()
                    }
                    return self.cleanInspection(statusEntries: ["!! .env.local"])
                },
                measureSize: { _ in 1_024 }
            ),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(staleCleanCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        XCTAssertEqual(inspectionCount, 2)
        guard case .refused(let finalCandidate) = result else {
            return XCTFail("Expected removal to be refused after final inspection found ignored evidence, got \(result)")
        }
        XCTAssertEqual(finalCandidate.state, .review([WorktreeCleanupCandidate.ignoredFilesReason]))
        XCTAssertEqual(finalCandidate.checks.first { $0.label == "No ignored files" }?.status, .review)
        XCTAssertEqual(finalCandidate.reviewEvidence.ignoredPreview?.items, [".env.local"])
    }

    func testRemovalServiceRefusesReviewCandidateWhenUntrackedFileEvidenceAppearsForSameReason() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([WorktreeCleanupCandidate.untrackedFilesReason]),
            checks: []
        )
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [worktreePath: cleanInspection(statusEntries: ["?? scratch.txt"])]
            ),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused after untracked-file evidence appeared, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.state, .review([WorktreeCleanupCandidate.untrackedFilesReason]))
        XCTAssertEqual(preflightCandidate.reviewEvidence.untrackedPreview?.items, ["scratch.txt"])
    }

    func testRemovalServiceRefusesReviewCandidateWhenLocalFileEvidenceCountChanges() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([WorktreeCleanupCandidate.untrackedFilesReason]),
            checks: [],
            reviewEvidence: WorktreeCleanupReviewEvidence(
                untrackedPreview: WorktreeCleanupUntrackedPreview(paths: ["a.txt", "b.txt", "c.txt"])
            )
        )
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [
                    worktreePath: cleanInspection(statusEntries: [
                        "?? a.txt",
                        "?? b.txt",
                        "?? c.txt",
                        "?? d.txt",
                    ]),
                ]
            ),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused after local-file evidence count changed, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.reviewEvidence.untrackedPreview?.items, ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(preflightCandidate.reviewEvidence.untrackedPreview?.totalCount, 4)
    }

    func testRemovalServiceRefusesReviewCandidateWhenCollapsedIgnoredEvidenceCountChanges() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([WorktreeCleanupCandidate.ignoredFilesReason]),
            checks: [],
            reviewEvidence: WorktreeCleanupReviewEvidence(
                ignoredPreview: WorktreeCleanupUntrackedPreview(paths: ["cache/a.local"])
            )
        )
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [
                    worktreePath: cleanInspection(statusEntries: [
                        "!! cache/a.local",
                        "!! cache/b.local",
                    ]),
                ]
            ),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused after collapsed ignored evidence count changed, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.reviewEvidence.ignoredPreview?.items, ["cache/"])
        XCTAssertEqual(preflightCandidate.reviewEvidence.ignoredPreview?.totalCount, 2)
    }

    func testRemovalServiceRefusesReviewCandidateWhenCollapsedIgnoredEvidencePathChanges() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([WorktreeCleanupCandidate.ignoredFilesReason]),
            checks: [],
            reviewEvidence: WorktreeCleanupReviewEvidence(
                ignoredPreview: WorktreeCleanupUntrackedPreview(paths: ["cache/a.local"])
            )
        )
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [
                    worktreePath: cleanInspection(statusEntries: [
                        "!! cache/b.local",
                    ]),
                ]
            ),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused after collapsed ignored evidence path changed, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.reviewEvidence.ignoredPreview?.items, ["cache/"])
        XCTAssertEqual(preflightCandidate.reviewEvidence.ignoredPreview?.totalCount, 1)
    }

    func testRemovalServiceRefusesReviewCandidateWhenUntrackedEvidenceDiffersOnlyByLeadingSpace() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([WorktreeCleanupCandidate.untrackedFilesReason]),
            checks: [],
            reviewEvidence: WorktreeCleanupReviewEvidence(
                untrackedPreview: WorktreeCleanupUntrackedPreview(paths: [" secret"])
            )
        )
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [worktreePath: cleanInspection(statusEntries: ["?? secret"])]
            ),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused after whitespace-distinct untracked evidence changed, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.reviewEvidence.untrackedPreview?.items, ["secret"])
        XCTAssertEqual(preflightCandidate.reviewEvidence.untrackedPreview?.totalCount, 1)
    }

    func testRemovalServiceRefusesReviewCandidateWhenIgnoredEvidenceDiffersOnlyByTrailingSpace() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([WorktreeCleanupCandidate.ignoredFilesReason]),
            checks: [],
            reviewEvidence: WorktreeCleanupReviewEvidence(
                ignoredPreview: WorktreeCleanupUntrackedPreview(paths: ["secret "])
            )
        )
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath],
                inspections: [worktreePath: cleanInspection(statusEntries: ["!! secret"])]
            ),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused after whitespace-distinct ignored evidence changed, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.reviewEvidence.ignoredPreview?.items, ["secret"])
        XCTAssertEqual(preflightCandidate.reviewEvidence.ignoredPreview?.totalCount, 1)
    }

    func testRemovalServiceRefusesReviewCandidateWhenLocalFileEvidenceDisappears() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let reviewCandidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Needs review",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review([WorktreeCleanupCandidate.untrackedFilesReason]),
            checks: [],
            reviewEvidence: WorktreeCleanupReviewEvidence(
                untrackedPreview: WorktreeCleanupUntrackedPreview(paths: ["scratch.txt"])
            )
        )
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(existingPaths: [worktreePath], inspections: [worktreePath: cleanInspection()]),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(reviewCandidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused after local-file evidence disappeared, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.state, .clean)
        XCTAssertEqual(preflightCandidate.reviewEvidence, .empty)
    }

    func testRemovalServiceRefusesStaleCleanCandidateWhenActivePathAppearsBeforePreflight() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let staleCleanCandidate = cleanupCandidate(path: worktreePath)
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(existingPaths: [worktreePath], inspections: [worktreePath: cleanInspection()]),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(staleCleanCandidate, sourceSessions: [session], activeProjectPaths: [worktreePath])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused once the path became active, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.state, .ignored(["Active cctop session is using this path"]))
    }

    func testRemovalServiceRefusesStaleCleanCandidateWhenActiveDescendantAppearsBeforePreflight() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let staleCleanCandidate = cleanupCandidate(path: worktreePath)
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(existingPaths: [worktreePath], inspections: [worktreePath: cleanInspection()]),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(
            staleCleanCandidate,
            sourceSessions: [session],
            activeProjectPaths: ["/Users/dev/.codex/worktrees/billing-api/pkg"]
        )

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused once a descendant path became active, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.state, .ignored(["Active cctop session is using this path"]))
    }

    func testRemovalServiceRefusesStaleCleanCandidateWhenActiveAliasAppearsBeforePreflight() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let aliasPath = "/tmp/billing-api-link"
        let session = historySession(path: worktreePath)
        let staleCleanCandidate = cleanupCandidate(path: worktreePath)
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(
                existingPaths: [worktreePath, aliasPath],
                inspections: [worktreePath: cleanInspection()],
                resolvedRoots: [aliasPath: worktreePath]
            ),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(
            staleCleanCandidate,
            sourceSessions: [session],
            activeProjectPaths: [aliasPath]
        )

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected removal to be refused once an alias path became active, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.state, .ignored(["Active cctop session is using this path"]))
    }

    func testRemovalServiceRefusesDetachedBranchReviewCandidateWithoutInvokingGit() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let candidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Detached cleanup",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            branchName: "unknown",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review(["Branch is unknown or detached"]),
            checks: []
        )
        let detachedInspection = GitWorktreeInspection(
            isRegisteredWorktree: true,
            isLinkedWorktree: true,
            isLocked: false,
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: nil,
            statusEntries: [],
            uniqueCommitCount: nil,
            failureReasons: ["Branch is unknown or detached"]
        )
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(existingPaths: [worktreePath], inspections: [worktreePath: detachedInspection]),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(candidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        guard case .refused(let preflightCandidate) = result else {
            return XCTFail("Expected detached branch review candidate to be refused, got \(result)")
        }
        XCTAssertEqual(preflightCandidate.state, .review(["Branch is unknown or detached"]))
    }

    func testRemovalServiceRefusesIgnoredCandidateWithoutInvokingGit() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let candidate = WorktreeCleanupCandidate(
            id: worktreePath,
            sessionName: "Ignored",
            worktreePath: worktreePath,
            worktreeName: "billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .ignored(["Active cctop session is using this path"]),
            checks: []
        )
        var didRunGit = false
        let service = WorktreeRemovalService(
            scanner: scanner(existingPaths: [worktreePath], inspections: [worktreePath: cleanInspection()]),
            runGit: { _ in
                didRunGit = true
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let result = service.remove(candidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertFalse(didRunGit)
        XCTAssertEqual(result, .refused(candidate))
    }

    func testRemovalServiceReturnsGitFailureOutput() {
        let worktreePath = "/Users/dev/.codex/worktrees/billing-api"
        let session = historySession(path: worktreePath)
        let candidate = cleanupCandidate(path: worktreePath)
        let failure = GitCommandResult(
            exitCode: 128,
            stdout: "",
            stderr: "fatal: contains modified or untracked files\n"
        )
        let service = WorktreeRemovalService(
            scanner: scanner(existingPaths: [worktreePath], inspections: [worktreePath: cleanInspection()]),
            runGit: { _ in failure }
        )

        let result = service.remove(candidate, sourceSessions: [session], activeProjectPaths: [])

        XCTAssertEqual(result, .failed(failure))
    }

    func testReviewRemovalConfirmationRequiresExtraStep() {
        let clean = cleanupCandidate(path: "/Users/dev/.codex/worktrees/clean")
        let review = WorktreeCleanupCandidate(
            id: "/Users/dev/.codex/worktrees/review",
            sessionName: "Needs review",
            worktreePath: "/Users/dev/.codex/worktrees/review",
            worktreeName: "review",
            branchName: "feature/review",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .review(["Worktree has untracked files"]),
            checks: []
        )

        XCTAssertEqual(WorktreeRemovalConfirmation.initial(for: clean), .final(clean))
        XCTAssertEqual(WorktreeRemovalConfirmation.initial(for: review), .reviewWarning(review))
        XCTAssertEqual(WorktreeRemovalConfirmation.reviewWarning(review).confirmedReviewWarning, .final(review))
        XCTAssertEqual(WorktreeRemovalConfirmation.reviewWarning(review).primaryButtonTitle, "Continue")
        XCTAssertEqual(WorktreeRemovalConfirmation.final(clean).primaryButtonTitle, "Remove")
        let offer = WorktreeForceRemovalOffer(
            candidate: review,
            failure: GitCommandResult(exitCode: 128, stdout: "", stderr: "use --force\n")
        )
        XCTAssertEqual(WorktreeRemovalConfirmation.force(offer).primaryButtonTitle, "Force Remove")
        XCTAssertTrue(WorktreeRemovalConfirmation.force(offer).message.contains("git worktree remove --force"))
        XCTAssertTrue(WorktreeRemovalConfirmation.force(offer).message.contains(review.worktreePath))
        XCTAssertTrue(WorktreeRemovalConfirmation.force(offer).message.contains(review.branchName))
    }

    func testCleanupViewsExposeOnlyRemoveActions() throws {
        let root = try repoRoot()
        let cleanupViewSources = try [
            "menubar/CctopMenubar/Views/WorktreeCleanupDetailView.swift",
            "menubar/CctopMenubar/Views/WorktreeCleanupTabView.swift",
            "menubar/CctopMenubar/Views/PopupView+Cleanup.swift",
        ].map { path in
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }.joined(separator: "\n")

        XCTAssertFalse(cleanupViewSources.contains("Copy Command"))
        XCTAssertFalse(cleanupViewSources.contains("Copy Suggested Command"))
        XCTAssertFalse(cleanupViewSources.contains("onCopyCommand"))
        XCTAssertFalse(cleanupViewSources.contains(".contextMenu"))
        XCTAssertFalse(cleanupViewSources.contains("Open in Finder"))
        XCTAssertFalse(cleanupViewSources.contains("Copy Path"))
        XCTAssertFalse(cleanupViewSources.contains("onOpenFinder"))
        XCTAssertFalse(cleanupViewSources.contains("onCopyPath"))
        XCTAssertFalse(cleanupViewSources.contains("Remove Worktree..."))
        XCTAssertTrue(cleanupViewSources.contains("\"Remove\""))
    }

    private func scanner(
        existingPaths: Set<String>,
        inspections: [String: GitWorktreeInspection] = [:],
        resolvedRoots: [String: String] = [:],
        sizes: [String: Int64] = ["/Users/dev/.codex/worktrees/billing-api": 1_024]
    ) -> WorktreeCleanupScanner {
        WorktreeCleanupScanner(
            fileExists: { existingPaths.contains($0) },
            resolveWorktreeRoot: { resolvedRoots[$0] },
            inspectGit: { path in
                inspections[path] ?? GitWorktreeInspection(
                    isRegisteredWorktree: false,
                    isLinkedWorktree: false,
                    isLocked: false,
                    mainWorktreePath: nil,
                    branchName: nil,
                    statusEntries: nil,
                    uniqueCommitCount: nil,
                    failureReasons: ["Path is not a registered Git worktree"]
                )
            },
            measureSize: { sizes[$0] }
        )
    }

    private func cleanInspection(
        branch: String = "feature/invoices",
        statusEntries: [String] = [],
        uniqueCommitCount: Int? = 0,
        isLocked: Bool = false,
        failureReasons: [String] = []
    ) -> GitWorktreeInspection {
        GitWorktreeInspection(
            isRegisteredWorktree: true,
            isLinkedWorktree: true,
            isLocked: isLocked,
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: branch,
            statusEntries: statusEntries,
            uniqueCommitCount: uniqueCommitCount,
            failureReasons: failureReasons
        )
    }

    private func worktreeEntry(
        _ path: String,
        branch: String,
        isPrunable: Bool = false,
        isLocked: Bool = false
    ) -> GitWorktreeListEntry {
        GitWorktreeListEntry(path: path, branchName: branch, isPrunable: isPrunable, isLocked: isLocked)
    }

    private func hiddenTrackedEditInspection(
        indexMarker: String,
        indexMode: String = "100644",
        indexObjectID: String = "index-clean",
        worktreeObjectID: String = "index-clean",
        worktreeMode: String = "100644",
        worktreeObjectExitCode: Int32 = 0,
        symlinkDestination: String? = nil,
        symlinkObjectID: String? = nil,
        sparseCheckRulesOutput: String? = nil
    ) -> GitWorktreeInspection {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let inspector = GitWorktreeInspector(
            runGit: { _, arguments in
            switch arguments {
            case ["worktree", "list", "--porcelain", "-z"]:
                return GitCommandResult(
                    exitCode: 0,
                    stdout: "worktree /Users/dev/projects/billing-api\0"
                        + "branch refs/heads/main\0\0"
                        + "worktree \(path)\0"
                        + "branch refs/heads/feature/invoices\0\0",
                    stderr: ""
                )
            case ["branch", "--show-current"]:
                return GitCommandResult(exitCode: 0, stdout: "feature/invoices\n", stderr: "")
            case ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=traditional"]:
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            case ["ls-files", "-s", "-v", "-z"]:
                return GitCommandResult(
                    exitCode: 0,
                    stdout: "\(indexMarker) \(indexMode) \(indexObjectID) 0\ttracked.txt\0H 100644 clean-id 0\tclean.txt\0",
                    stderr: ""
                )
            case ["hash-object", "--path=tracked.txt", "--", "tracked.txt"]:
                return GitCommandResult(
                    exitCode: worktreeObjectExitCode,
                    stdout: worktreeObjectExitCode == 0 ? "\(worktreeObjectID)\n" : "",
                    stderr: worktreeObjectExitCode == 0 ? "" : "fatal: could not open 'tracked.txt': No such file or directory"
                )
            case ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]:
                return GitCommandResult(exitCode: 0, stdout: "origin/feature/invoices\n", stderr: "")
            case ["rev-list", "--count", "@{u}..HEAD"]:
                return GitCommandResult(exitCode: 0, stdout: "0\n", stderr: "")
            case ["submodule", "status", "--recursive"]:
                return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            default:
                return GitCommandResult(exitCode: 1, stdout: "", stderr: "unexpected \(arguments)")
            }
            },
            runGitWithInput: { _, arguments, input in
                switch arguments {
                case ["hash-object", "--stdin"] where input == symlinkDestination:
                    return GitCommandResult(exitCode: 0, stdout: "\(symlinkObjectID ?? "")\n", stderr: "")
                case ["sparse-checkout", "check-rules", "-z"] where input == "tracked.txt\0":
                    guard let sparseCheckRulesOutput else {
                        return GitCommandResult(exitCode: 128, stdout: "", stderr: "fatal: this worktree is not sparse")
                    }
                    return GitCommandResult(exitCode: 0, stdout: sparseCheckRulesOutput, stderr: "")
                default:
                    return GitCommandResult(exitCode: 1, stdout: "", stderr: "unexpected \(arguments)")
                }
            },
            worktreeFileMode: { filePath in
                filePath == "\(path)/tracked.txt" && worktreeObjectExitCode == 0 ? worktreeMode : nil
            },
            symlinkDestination: { filePath in
                filePath == "\(path)/tracked.txt" ? symlinkDestination : nil
            }
        )
        return inspector.inspect(path: path)
    }

    private func historySession(
        id: String = "ended",
        path: String = "/Users/dev/.codex/worktrees/billing-api",
        name: String = "Generate invoice retry path",
        branch: String = "feature/invoices",
        endedAt: Date? = nil
    ) -> Session {
        let lastActivity = endedAt ?? now
        return Session(
            sessionId: id,
            projectPath: path,
            projectName: URL(fileURLWithPath: path).lastPathComponent,
            branch: branch,
            status: .idle,
            lastPrompt: nil,
            lastActivity: lastActivity,
            startedAt: lastActivity.addingTimeInterval(-300),
            terminal: TerminalInfo(program: "Code"),
            pid: nil,
            lastTool: nil,
            lastToolDetail: nil,
            notificationMessage: nil,
            sessionName: name,
            endedAt: endedAt ?? lastActivity
        )
    }

    private func activeSession(
        id: String = "active",
        path: String,
        name: String = "Active feature work",
        branch: String = "feature/active"
    ) -> Session {
        Session(
            sessionId: id,
            projectPath: path,
            projectName: URL(fileURLWithPath: path).lastPathComponent,
            branch: branch,
            status: .waitingInput,
            lastPrompt: nil,
            lastActivity: now,
            startedAt: now.addingTimeInterval(-300),
            terminal: TerminalInfo(program: "Code"),
            pid: nil,
            lastTool: nil,
            lastToolDetail: nil,
            notificationMessage: nil,
            sessionName: name,
            endedAt: nil
        )
    }

    private func cleanupCandidate(path: String) -> WorktreeCleanupCandidate {
        WorktreeCleanupCandidate(
            id: path,
            sessionName: "Generate invoice retry path",
            worktreePath: path,
            worktreeName: URL(fileURLWithPath: path).lastPathComponent,
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .clean,
            checks: []
        )
    }

    @MainActor
    private func waitForCleanupCandidates(
        _ manager: WorktreeCleanupManager,
        matching predicate: ([WorktreeCleanupCandidate]) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<50 {
            if predicate(manager.candidates) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for cleanup candidates", file: file, line: line)
    }

    @MainActor
    private func popupView(
        cleanupCandidates: [WorktreeCleanupCandidate],
        pluginManager: PluginManager? = nil,
        navigate: NavigateController? = nil,
        initialTab: PopupTab = .active,
        onCleanupTabVisible: @escaping () -> Void = {},
        onLayoutChanged: @escaping () -> Void = {}
    ) -> PopupView {
        PopupView(
            sessions: [],
            cleanupCandidates: cleanupCandidates,
            updater: DisabledUpdater(),
            pluginManager: pluginManager ?? inertPluginManager(),
            navigate: navigate,
            initialTab: initialTab,
            onCleanupTabVisible: onCleanupTabVisible,
            onLayoutChanged: onLayoutChanged
        )
    }

    @MainActor
    private func inertPluginManager() -> PluginManager {
        PluginManager(homeDirectory: URL(fileURLWithPath: "/nonexistent"), refreshOnInit: false)
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
