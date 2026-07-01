import XCTest
@testable import CctopMenubar
import SwiftUI

// swiftlint:disable file_length
// swiftlint:disable type_body_length
@MainActor
final class WorktreeCleanupScenarioSnapshotTests: XCTestCase {
    private struct Scenario {
        let clean: WorktreeCleanupCandidate
        let review: WorktreeCleanupCandidate
        let untrackedOnly: WorktreeCleanupCandidate
        let secondaryReview: WorktreeCleanupCandidate
        let longStress: WorktreeCleanupCandidate
        let unknownSafety: WorktreeCleanupCandidate

        var allCandidates: [WorktreeCleanupCandidate] {
            [clean, review, untrackedOnly, secondaryReview, longStress, unknownSafety]
        }

        var productInputCandidates: [WorktreeCleanupCandidate] {
            allCandidates
        }
    }

    private struct CandidateSeed {
        let path: String
        let sessionName: String
        let branch: String
        let lastActiveAt: Date
        let storageBytes: Int64?
        let state: WorktreeCleanupCandidate.State
        let checks: [WorktreeCleanupCheck]?
        let reviewEvidence: WorktreeCleanupReviewEvidence?

        init(
            path: String,
            sessionName: String,
            branch: String,
            lastActiveAt: Date,
            storageBytes: Int64?,
            state: WorktreeCleanupCandidate.State,
            checks: [WorktreeCleanupCheck]? = nil,
            reviewEvidence: WorktreeCleanupReviewEvidence? = nil
        ) {
            self.path = path
            self.sessionName = sessionName
            self.branch = branch
            self.lastActiveAt = lastActiveAt
            self.storageBytes = storageBytes
            self.state = state
            self.checks = checks
            self.reviewEvidence = reviewEvidence
        }
    }

    func testGenerateCleanupScenarioScreenshots() throws {
        let scenario = cleanupScenario()
        try renderListScreenshots(for: scenario)
        try renderDetailScreenshots(for: scenario)
        try renderConfirmationScreenshots(for: scenario)
        try renderSpecialStateScreenshots(for: scenario)
    }

    private func renderListScreenshots(for scenario: Scenario) throws {
        let actionableCount = scenario.productInputCandidates.filter(\.state.isActionable).count
        XCTAssertEqual(actionableCount, scenario.allCandidates.count)
        XCTAssertEqual(scenario.productInputCandidates.count, actionableCount)

        let mixedList = cleanupPopup(candidates: scenario.productInputCandidates)
        let mixedListSize = try renderScreenshot(
            view: mixedList, colorScheme: .dark, filename: "worktree-cleanup-list-mixed-dark.png"
        )
        try renderScreenshot(
            view: mixedList, colorScheme: .light, filename: "worktree-cleanup-list-mixed-light.png"
        )
        XCTAssertLessThanOrEqual(mixedListSize.width, 320)
        XCTAssertLessThanOrEqual(mixedListSize.height, 430)
    }

    private func renderDetailScreenshots(for scenario: Scenario) throws {
        let cleanSize = try renderScreenshot(
            view: cleanupPopup(candidates: scenario.productInputCandidates, selectedCandidate: scenario.clean),
            colorScheme: .dark,
            filename: "worktree-cleanup-detail-clean.png"
        )
        let reviewSize = try renderScreenshot(
            view: cleanupPopup(candidates: scenario.productInputCandidates, selectedCandidate: scenario.review),
            colorScheme: .dark,
            filename: "worktree-cleanup-detail-review.png"
        )
        let longSize = try renderScreenshot(
            view: cleanupPopup(candidates: scenario.productInputCandidates, selectedCandidate: scenario.longStress),
            colorScheme: .dark,
            filename: "worktree-cleanup-detail-long-stress.png"
        )
        let untrackedOnlySize = try renderScreenshot(
            view: cleanupPopup(candidates: scenario.productInputCandidates, selectedCandidate: scenario.untrackedOnly),
            colorScheme: .dark,
            filename: "worktree-cleanup-detail-untracked-only.png"
        )
        let unknownSize = try renderScreenshot(
            view: cleanupPopup(candidates: scenario.productInputCandidates, selectedCandidate: scenario.unknownSafety),
            colorScheme: .dark,
            filename: "worktree-cleanup-detail-unknown-safety.png"
        )
        let forceOffer = forceRemovalOffer(for: scenario.untrackedOnly)
        let forceOfferSize = try renderScreenshot(
            view: cleanupDetail(
                candidate: scenario.untrackedOnly,
                notice: WorktreeRemovalNotice(
                    title: "Remove Failed",
                    message: cleanupForceOfferNoticeMessage(),
                    forceOffer: forceOffer
                )
            ),
            colorScheme: .dark,
            filename: "worktree-cleanup-force-offer.png"
        )
        let forceFailureSize = try renderScreenshot(
            view: cleanupDetail(
                candidate: scenario.untrackedOnly,
                notice: WorktreeRemovalNotice(
                    title: "Remove Failed",
                    message: "fatal: failed to remove worktree: permission denied"
                )
            ),
            colorScheme: .dark,
            filename: "worktree-cleanup-force-failure.png"
        )

        XCTAssertLessThanOrEqual(cleanSize.width, 320)
        XCTAssertLessThanOrEqual(reviewSize.width, 320)
        XCTAssertLessThanOrEqual(longSize.width, 320)
        XCTAssertLessThanOrEqual(untrackedOnlySize.width, 320)
        XCTAssertLessThanOrEqual(unknownSize.width, 320)
        XCTAssertLessThanOrEqual(forceOfferSize.width, 320)
        XCTAssertLessThanOrEqual(forceFailureSize.width, 320)
        XCTAssertLessThanOrEqual(cleanSize.height, 430)
        XCTAssertLessThanOrEqual(reviewSize.height, 430)
        XCTAssertLessThanOrEqual(longSize.height, 430)
        XCTAssertLessThanOrEqual(untrackedOnlySize.height, 430)
        XCTAssertLessThanOrEqual(unknownSize.height, 430)
        XCTAssertLessThanOrEqual(forceOfferSize.height, 430)
        XCTAssertLessThanOrEqual(forceFailureSize.height, 430)
        XCTAssertEqual(scenario.unknownSafety.formattedStorage, "Unknown")
    }

    private func renderConfirmationScreenshots(for scenario: Scenario) throws {
        let reviewSize = try renderScreenshot(
            view: CleanupConfirmationProofView(confirmation: .reviewWarning(scenario.review)),
            colorScheme: .dark,
            filename: "worktree-cleanup-confirmation-review.png"
        )
        let finalSize = try renderScreenshot(
            view: CleanupConfirmationProofView(confirmation: .final(scenario.clean)),
            colorScheme: .dark,
            filename: "worktree-cleanup-confirmation-final.png"
        )
        let forceSize = try renderScreenshot(
            view: CleanupConfirmationProofView(confirmation: .force(forceRemovalOffer(for: scenario.review))),
            colorScheme: .dark,
            filename: "worktree-cleanup-confirmation-force.png"
        )

        XCTAssertLessThanOrEqual(reviewSize.width, 320)
        XCTAssertLessThanOrEqual(finalSize.width, 320)
        XCTAssertLessThanOrEqual(forceSize.width, 320)
        XCTAssertLessThanOrEqual(reviewSize.height, 430)
        XCTAssertLessThanOrEqual(finalSize.height, 430)
        XCTAssertLessThanOrEqual(forceSize.height, 430)
    }

    private func renderSpecialStateScreenshots(for scenario: Scenario) throws {
        let overflow = overflowCandidates()
        XCTAssertGreaterThanOrEqual(overflow.count, 8)

        let selectedRow = WorktreeCleanupTabView(
            candidates: overflow,
            selectedIndex: 1,
            selectedCandidate: Binding<WorktreeCleanupCandidate?>.constant(nil),
            onRemove: { _, _ in }
        )
        try renderScreenshot(
            view: selectedRow, colorScheme: .dark, filename: "worktree-cleanup-list-keyboard-selected.png"
        )

        let emptyState = WorktreeCleanupTabView(
            candidates: [],
            selectedIndex: nil,
            selectedCandidate: Binding<WorktreeCleanupCandidate?>.constant(nil),
            onRemove: { _, _ in }
        )
        try renderScreenshot(view: emptyState, colorScheme: .dark, filename: "worktree-cleanup-empty.png")
    }

    @discardableResult
    private func renderScreenshot(
        view: some View, colorScheme: ColorScheme, filename: String, width: CGFloat = 320
    ) throws -> NSSize {
        let docsDir = snapshotOutputDirectory(named: "cctop-worktree-cleanup-screenshots")
        let outputPath = "\(docsDir)/\(filename)"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: docsDir), withIntermediateDirectories: true
        )

        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        let styled = view
            .frame(width: width)
            .background {
                PanelSurfaceBackground(usesMaterial: false)
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

    private func cleanupPopup(
        candidates: [WorktreeCleanupCandidate],
        selectedCandidate: WorktreeCleanupCandidate? = nil,
        sessions: [Session] = Session.qaShowcase
    ) -> PopupView {
        PopupView(
            sessions: sessions,
            recentProjects: RecentProject.mockRecents,
            cleanupCandidates: candidates,
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            initialTab: .cleanup,
            initialCleanupCandidate: selectedCandidate
        )
    }

    private func cleanupDetail(
        candidate: WorktreeCleanupCandidate,
        notice: WorktreeRemovalNotice
    ) -> WorktreeCleanupDetailView {
        WorktreeCleanupDetailView(candidate: candidate, onBack: {}, removalNotice: notice)
    }

    private func forceRemovalOffer(for candidate: WorktreeCleanupCandidate) -> WorktreeForceRemovalOffer {
        WorktreeForceRemovalOffer(
            candidate: candidate,
            failure: GitCommandResult(
                exitCode: 128,
                stdout: "",
                stderr: cleanupForceEligibleFailureMessage(for: candidate)
            )
        )
    }

    private func cleanupForceEligibleFailureMessage(for candidate: WorktreeCleanupCandidate) -> String {
        "fatal: '\(candidate.worktreePath)' contains modified or untracked files; use --force to delete it"
    }

    private func cleanupForceOfferNoticeMessage() -> String {
        "Plain removal failed; Git suggested --force for local files."
    }

    private func cleanupScenario(now: Date = Date()) -> Scenario {
        let clean = cleanupScenarioCandidate(
            CandidateSeed(
                path: "/Users/st0012/projects/rdoc/.claude/worktrees/stupefied-panini-cface5",
                sessionName: "Check RDoc option parser edge cases",
                branch: "claude/stupefied-panini-cface5",
                lastActiveAt: now.addingTimeInterval(-86_400 * 22),
                storageBytes: 4 * 1_024 * 1_024,
                state: .clean
            )
        )
        let review = cleanupScenarioCandidate(
            CandidateSeed(
                path: "/Users/st0012/projects/cctop/.claude/worktrees/elegant-euler-73a179",
                sessionName: "Investigate cleanup tab layout",
                branch: "claude/elegant-euler-73a179",
                lastActiveAt: now.addingTimeInterval(-86_400 * 14),
                storageBytes: 426 * 1_024 * 1_024,
                state: .review([
                    "Worktree has uncommitted tracked changes",
                    WorktreeCleanupCandidate.untrackedFilesReason,
                    WorktreeCleanupCandidate.ignoredFilesReason,
                    "No upstream branch",
                ]),
                reviewEvidence: localFilePreviewEvidence(
                    untrackedPaths: [
                        "scratch notes.md",
                        "generated/output.json",
                    ],
                    ignoredPaths: [
                        ".env.local",
                        "cache/build.log",
                    ]
                )
            )
        )
        let untrackedOnly = cleanupScenarioCandidate(
            CandidateSeed(
                path: "/Users/st0012/projects/cctop/.claude/worktrees/untracked-local-notes",
                sessionName: "Review local notes before cleanup",
                branch: "claude/untracked-local-notes",
                lastActiveAt: now.addingTimeInterval(-86_400 * 17),
                storageBytes: 12 * 1_024 * 1_024,
                state: .review([WorktreeCleanupCandidate.untrackedFilesReason]),
                reviewEvidence: untrackedPreviewEvidence(paths: [
                    "foo.rb",
                    "bar.rb",
                    "something/",
                    "notes with spaces.md",
                    "tmp/cache.json",
                    "very-long-local-directory-name-for-middle-truncation/output.txt",
                ])
            )
        )
        let secondaryReview = cleanupScenarioCandidate(
            CandidateSeed(
                path: "/Users/st0012/projects/cctop/.claude/worktrees/strange-heisenberg-8777cd",
                sessionName: "Audit cleanup scanner worktree sources",
                branch: "claude/strange-heisenberg-8777cd",
                lastActiveAt: now.addingTimeInterval(-86_400 * 19),
                storageBytes: 16 * 1_024 * 1_024,
                state: .review([
                    "No upstream branch",
                    "Branch commit safety could not be verified",
                ])
            )
        )
        let unknownSafety = unknownSafetyCandidate(now: now)
        return Scenario(
            clean: clean,
            review: review,
            untrackedOnly: untrackedOnly,
            secondaryReview: secondaryReview,
            longStress: worstCaseReviewCleanupCandidate(now: now),
            unknownSafety: unknownSafety
        )
    }

    private func cleanupScenarioCandidate(_ seed: CandidateSeed) -> WorktreeCleanupCandidate {
        WorktreeCleanupCandidate(
            id: seed.path,
            sessionName: seed.sessionName,
            worktreePath: seed.path,
            worktreeName: URL(fileURLWithPath: seed.path).lastPathComponent,
            branchName: seed.branch,
            lastActiveAt: seed.lastActiveAt,
            storageBytes: seed.storageBytes,
            state: seed.state,
            checks: seed.checks ?? cleanupScenarioChecks(for: seed.state, storageBytes: seed.storageBytes),
            reviewEvidence: seed.reviewEvidence ?? WorktreeCleanupCandidate.mockReviewEvidence(for: seed.state)
        )
    }

    private func worstCaseReviewCleanupCandidate(now: Date) -> WorktreeCleanupCandidate {
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

    private func unknownSafetyCandidate(now: Date) -> WorktreeCleanupCandidate {
        cleanupScenarioCandidate(
            CandidateSeed(
                path: "/Users/st0012/projects/codex/.codex/worktrees/detached-unknown-safety",
                sessionName: "Inspect detached worktree with unknown cleanup safety",
                branch: "detached@unknown",
                lastActiveAt: now.addingTimeInterval(-86_400 * 31),
                storageBytes: nil,
                state: .review([
                    "Branch is unknown or detached",
                    "Git status could not be read",
                    "Main checkout path could not be verified",
                    "Branch upstream or commit safety could not be verified",
                    "Worktree is locked",
                ]),
                checks: [
                    WorktreeCleanupCheck(label: "No active cctop sessions here", status: .ok),
                    WorktreeCleanupCheck(label: "Path is a registered linked worktree", status: .ok),
                    WorktreeCleanupCheck(label: "No uncommitted tracked changes", status: .review),
                    WorktreeCleanupCheck(label: "No untracked files", status: .review),
                    WorktreeCleanupCheck(label: "No ignored files", status: .review),
                    WorktreeCleanupCheck(label: "Branch has no unique local commits", status: .review),
                    WorktreeCleanupCheck(label: "Main checkout path is known", status: .review),
                    WorktreeCleanupCheck(label: "Worktree is not locked", status: .review),
                    WorktreeCleanupCheck(label: "Storage size scan completed", status: .ignored),
                ]
            )
        )
    }

    private func overflowCandidates(now: Date = Date()) -> [WorktreeCleanupCandidate] {
        let names = [
            "elegant-euler-73a179",
            "heuristic-newton-a46d2f",
            "optimistic-mestorf-1d360b",
            "strange-heisenberg-8777cd",
            "zen-ptolemy-b9795a",
            "tender-babbage-2ad835",
            "magical-herschel-4b3381",
            "stupefied-panini-cface5",
            "unruffled-yalow-3fad0c",
        ]
        return names.enumerated().map { index, name in
            cleanupScenarioCandidate(
                CandidateSeed(
                    path: "/Users/st0012/projects/cctop/.claude/worktrees/\(name)",
                    sessionName: "Review cleanup candidate with intentionally long row label \(index + 1)",
                    branch: "claude/\(name)-with-extra-long-branch-name",
                    lastActiveAt: now.addingTimeInterval(TimeInterval(-86_400 * (index + 3))),
                    storageBytes: Int64(index + 1) * 1_073_741_824,
                    state: index == 0 ? .clean : .review([WorktreeCleanupCandidate.untrackedFilesReason])
                )
            )
        }
    }

    private func cleanupScenarioChecks(
        for state: WorktreeCleanupCandidate.State,
        storageBytes: Int64?
    ) -> [WorktreeCleanupCheck] {
        let needsReview = !state.reasons.isEmpty
        return [
            WorktreeCleanupCheck(label: "No active cctop sessions here", status: .ok),
            WorktreeCleanupCheck(label: "Path is a registered linked worktree", status: .ok),
            WorktreeCleanupCheck(label: "No uncommitted tracked changes", status: needsReview ? .review : .ok),
            WorktreeCleanupCheck(label: "No untracked files", status: needsReview ? .review : .ok),
            WorktreeCleanupCheck(
                label: "No ignored files",
                status: state.reasons.contains(WorktreeCleanupCandidate.ignoredFilesReason) ? .review : .ok
            ),
            WorktreeCleanupCheck(label: "Branch has no unique local commits", status: needsReview ? .review : .ok),
            WorktreeCleanupCheck(label: "Worktree is not locked", status: .ok),
            WorktreeCleanupCheck(label: "Storage size scan completed", status: storageBytes == nil ? .ignored : .ok),
        ]
    }

    private func untrackedPreviewEvidence(paths: [String]) -> WorktreeCleanupReviewEvidence {
        guard let preview = WorktreeCleanupUntrackedPreview(paths: paths) else {
            return .empty
        }
        return WorktreeCleanupReviewEvidence(untrackedPreview: preview)
    }

    private func localFilePreviewEvidence(untrackedPaths: [String], ignoredPaths: [String]) -> WorktreeCleanupReviewEvidence {
        WorktreeCleanupReviewEvidence(
            untrackedPreview: WorktreeCleanupUntrackedPreview(paths: untrackedPaths),
            ignoredPreview: WorktreeCleanupUntrackedPreview(paths: ignoredPaths)
        )
    }

    private func inertPluginManager() -> PluginManager {
        PluginManager(homeDirectory: URL(fileURLWithPath: "/nonexistent"), refreshOnInit: false)
    }
}

private struct CleanupConfirmationProofView: View {
    let confirmation: WorktreeRemovalConfirmation

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 18)
            VStack(alignment: .leading, spacing: 12) {
                Text(confirmation.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Text(confirmation.message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous)
                                .fill(Color.panelControlBackground)
                        }
                    Text(confirmation.primaryButtonTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.statusAttention)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous)
                                .fill(Color.statusAttention.opacity(0.10))
                        }
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: AppChrome.groupCornerRadius, style: .continuous)
                    .fill(Color.groupedContentBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppChrome.groupCornerRadius, style: .continuous)
                    .stroke(Color.groupedRowBorder, lineWidth: 1)
            }
            .padding(16)
            Spacer(minLength: 18)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}
// swiftlint:enable type_body_length
// swiftlint:enable file_length
