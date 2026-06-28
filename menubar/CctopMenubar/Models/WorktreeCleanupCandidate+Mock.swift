import Foundation

extension WorktreeCleanupCandidate {
    static func mock(
        path: String = "/Users/dev/.codex/worktrees/billing-api",
        sessionName: String = "Generate invoice retry path",
        branch: String = "feature/invoices",
        storageBytes: Int64? = 842 * 1_024 * 1_024,
        state: State = .clean,
        reviewEvidence: WorktreeCleanupReviewEvidence? = nil
    ) -> WorktreeCleanupCandidate {
        WorktreeCleanupCandidate(
            id: path,
            sessionName: sessionName,
            worktreePath: path,
            worktreeName: URL(fileURLWithPath: path).lastPathComponent,
            branchName: branch,
            lastActiveAt: Date().addingTimeInterval(-7_200),
            storageBytes: storageBytes,
            state: state,
            suggestedCommand: state.isClean ? "git -C /Users/dev/projects/billing-api worktree remove \(path)" : nil,
            checks: [
                WorktreeCleanupCheck(label: "No active cctop sessions here", status: .ok),
                WorktreeCleanupCheck(label: "Path is a registered linked worktree", status: .ok),
                WorktreeCleanupCheck(label: "No uncommitted tracked changes", status: .ok),
                WorktreeCleanupCheck(label: "No untracked files", status: .ok),
                WorktreeCleanupCheck(label: "Branch has no unique local commits", status: .ok),
                WorktreeCleanupCheck(label: "Storage size scan completed", status: storageBytes == nil ? .review : .ok),
            ],
            reviewEvidence: reviewEvidence ?? mockReviewEvidence(for: state)
        )
    }

    static func mockReviewEvidence(for state: State) -> WorktreeCleanupReviewEvidence {
        guard state.reasons.contains(untrackedFilesReason),
              let preview = WorktreeCleanupUntrackedPreview(paths: [
                  "scratch notes.md",
                  "generated/output.json",
                  "local-fixtures/sample data.json",
                  "tmp/",
              ]) else {
            return .empty
        }
        return WorktreeCleanupReviewEvidence(untrackedPreview: preview)
    }

    static let mockCandidates: [WorktreeCleanupCandidate] = [
        .mock(),
        .mock(
            path: "/Users/dev/.codex/worktrees/auth-rewrite-spike",
            sessionName: "Try auth rewrite spike",
            branch: "try/auth-flow",
            storageBytes: 1_800_000_000,
            state: .review(["Worktree has untracked files"])
        ),
        .mock(
            path: "/Users/dev/.codex/worktrees/site-copy-variants",
            sessionName: "Draft launch copy variants",
            branch: "copy/launch",
            storageBytes: 216 * 1_024 * 1_024,
            state: .ignored(["Path is the main checkout, not a linked worktree"])
        ),
    ]
}
