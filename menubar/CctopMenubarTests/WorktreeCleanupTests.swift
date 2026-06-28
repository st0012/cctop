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

    func testUntrackedFilesProduceReview() {
        let path = "/Users/dev/.codex/worktrees/billing-api"
        let inspection = cleanInspection(statusEntries: ["?? scratch.txt"])

        let candidate = scanner(
            existingPaths: [path],
            inspections: [path: inspection]
        ).candidates(from: [historySession(path: path)], activeProjectPaths: [])[0]

        XCTAssertEqual(candidate.state, .review(["Worktree has untracked files"]))
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
            candidate.checks.filter { $0.label == "No uncommitted tracked changes" || $0.label == "No untracked files" }
                .map(\.status),
            [.review, .review]
        )
    }

    func testInspectorReadsZPorcelainStatusWithAllUntrackedFiles() {
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
            case ["status", "--porcelain=v1", "-z", "--untracked-files=all"]:
                statusArguments = arguments
                return GitCommandResult(
                    exitCode: 0,
                    stdout: "?? file with spaces.txt\0?? nested/path.txt\0 M tracked.swift\0",
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

        XCTAssertEqual(statusArguments, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        XCTAssertEqual(inspection.statusEntries, ["?? file with spaces.txt", "?? nested/path.txt", " M tracked.swift"])
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

    func testZStatusParserPreservesPathsAndExcludesTrackedRenameCopyFromUntrackedPreview() {
        let entries = GitWorktreeInspector.parseStatusEntries(
            "?? foo bar.rb\0"
                + "?? nested/path with spaces.txt\0"
                + "R  renamed new.swift\0renamed old.swift\0"
                + "C  copied new.swift\0copied old.swift\0"
                + " M Sources/App.swift\0"
        )

        XCTAssertEqual(entries, [
            "?? foo bar.rb",
            "?? nested/path with spaces.txt",
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

    func testPopupTabAvailabilityIncludesCleanupOnlyWhenCandidatesExist() {
        XCTAssertEqual(
            PopupTab.availableTabs(hasIdleSessions: false, hasRecentProjects: false, hasCleanupCandidates: false),
            [.active]
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

    func testRemovalServiceLetsGitRefuseReviewCandidateWithDirtyPreflight() {
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
            state: .review(["Worktree has untracked files"]),
            checks: []
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

    func testRemovalServiceDoesNotDeleteWorktreeFoldersDirectly() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "menubar/CctopMenubar/Services/WorktreeRemovalService.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("removeItem"))
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
    }

    func testCleanupViewsExposeOnlyRemoveActions() throws {
        let root = try repoRoot()
        let cleanupViewSources = try [
            "menubar/CctopMenubar/Views/WorktreeCleanupDetailView.swift",
            "menubar/CctopMenubar/Views/WorktreeCleanupTabView.swift",
            "menubar/CctopMenubar/Views/PopupView+EmptyState.swift",
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

    func testUntrackedPreviewDoesNotUseDisclosureControl() throws {
        let root = try repoRoot()
        let detailViewSource = try String(
            contentsOf: root.appendingPathComponent("menubar/CctopMenubar/Views/WorktreeCleanupDetailView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(detailViewSource.contains("chevron.right"))
        XCTAssertFalse(detailViewSource.contains("chevron.down"))
        XCTAssertFalse(detailViewSource.contains("isExpanded.toggle()"))
    }

    func testCleanupCommandStringSurfaceIsRemoved() throws {
        let root = try repoRoot()
        let cleanupSources = try [
            "menubar/CctopMenubar/Models/WorktreeCleanupCandidate.swift",
            "menubar/CctopMenubar/Models/WorktreeCleanupCandidate+Mock.swift",
            "menubar/CctopMenubar/Services/WorktreeCleanupScanner.swift",
            "menubar/CctopMenubarTests/SnapshotTests.swift",
        ].map { path in
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }.joined(separator: "\n")

        XCTAssertFalse(cleanupSources.contains("suggestedCommand"))
        XCTAssertFalse(cleanupSources.contains("shellQuote"))
        XCTAssertFalse(cleanupSources.contains("Copy Command"))
    }

    private func scanner(
        existingPaths: Set<String>,
        inspections: [String: GitWorktreeInspection] = [:],
        sizes: [String: Int64] = ["/Users/dev/.codex/worktrees/billing-api": 1_024]
    ) -> WorktreeCleanupScanner {
        WorktreeCleanupScanner(
            fileExists: { existingPaths.contains($0) },
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
        isLocked: Bool = false
    ) -> GitWorktreeInspection {
        GitWorktreeInspection(
            isRegisteredWorktree: true,
            isLinkedWorktree: true,
            isLocked: isLocked,
            mainWorktreePath: "/Users/dev/projects/billing-api",
            branchName: branch,
            statusEntries: statusEntries,
            uniqueCommitCount: uniqueCommitCount,
            failureReasons: []
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
            branchName: "feature/invoices",
            lastActiveAt: now,
            storageBytes: 1_024,
            state: .clean,
            checks: []
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
