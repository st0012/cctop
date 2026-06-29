import Foundation

struct WorktreeCleanupCandidate: Identifiable, Equatable {
    static let untrackedFilesReason = "Worktree has untracked files"
    static let ignoredFilesReason = "Worktree has ignored files"
    static let trackedChangesReason = "Worktree has uncommitted tracked changes"
    static let initializedSubmodulesReason = "Worktree contains initialized submodules"
    static let indexHiddenTrackedFilesReason = "Worktree has tracked files hidden by Git index flags"
    static let statusUnreadableReason = "Git status could not be read"
    private static let localFileReasons = [untrackedFilesReason, ignoredFilesReason]

    enum State: Equatable {
        case clean
        case review([String])
        case ignored([String])

        var label: String {
            switch self {
            case .clean: return "Clean"
            case .review: return "Review"
            case .ignored: return "Ignored"
            }
        }

        var reasons: [String] {
            switch self {
            case .clean: return []
            case .review(let reasons), .ignored(let reasons): return reasons
            }
        }

        var isClean: Bool {
            if case .clean = self { return true }
            return false
        }

        var isActionable: Bool {
            switch self {
            case .clean, .review:
                return true
            case .ignored:
                return false
            }
        }
    }

    let id: String
    let sessionName: String
    let worktreePath: String
    let worktreeName: String
    let mainWorktreePath: String?
    let branchName: String
    let lastActiveAt: Date
    let storageBytes: Int64?
    let state: State
    let checks: [WorktreeCleanupCheck]
    let reviewEvidence: WorktreeCleanupReviewEvidence

    init(
        id: String,
        sessionName: String,
        worktreePath: String,
        worktreeName: String,
        mainWorktreePath: String? = nil,
        branchName: String,
        lastActiveAt: Date,
        storageBytes: Int64?,
        state: State,
        checks: [WorktreeCleanupCheck],
        reviewEvidence: WorktreeCleanupReviewEvidence = .empty
    ) {
        self.id = id
        self.sessionName = sessionName
        self.worktreePath = worktreePath
        self.worktreeName = worktreeName
        self.mainWorktreePath = mainWorktreePath
        self.branchName = branchName
        self.lastActiveAt = lastActiveAt
        self.storageBytes = storageBytes
        self.state = state
        self.checks = checks
        self.reviewEvidence = reviewEvidence
    }

    var formattedStorage: String {
        Self.formatStorage(bytes: storageBytes)
    }

    func visibleReviewReasons(limit: Int = 3) -> [String] {
        let reasons = state.reasons
        guard limit > 0 else { return [] }
        let cappedReasons = Array(reasons.prefix(limit))
        guard let localFileReason = Self.localFileReasons.first(where: { reason in
            guard let index = reasons.firstIndex(of: reason) else { return false }
            return index >= limit && !cappedReasons.contains(reason)
        }) else {
            return cappedReasons
        }
        if limit == 1 {
            return [localFileReason]
        }
        return Array(reasons.prefix(limit - 1)) + [localFileReason]
    }

    func remainingReviewReasonCount(limit: Int = 3) -> Int {
        max(state.reasons.count - visibleReviewReasons(limit: limit).count, 0)
    }

    static func formatStorage(bytes: Int64?) -> String {
        guard let bytes else { return "Unknown" }
        if bytes < 1_024 { return "\(bytes) B" }
        let kilobytes = Double(bytes) / 1_024.0
        if kilobytes < 1_024 { return "\(Int(kilobytes.rounded())) KB" }
        let megabytes = kilobytes / 1_024.0
        if megabytes < 1_024 { return "\(Int(megabytes.rounded())) MB" }
        let gigabytes = megabytes / 1_024.0
        let rounded = (gigabytes * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded)) GB"
        }
        return String(format: "%.1f GB", rounded)
    }
}

struct WorktreeCleanupReviewEvidence: Equatable {
    static let empty = WorktreeCleanupReviewEvidence()

    let untrackedPreview: WorktreeCleanupUntrackedPreview?
    let ignoredPreview: WorktreeCleanupUntrackedPreview?

    init(
        untrackedPreview: WorktreeCleanupUntrackedPreview? = nil,
        ignoredPreview: WorktreeCleanupUntrackedPreview? = nil
    ) {
        self.untrackedPreview = untrackedPreview
        self.ignoredPreview = ignoredPreview
    }

    var hasLocalFilePreview: Bool {
        untrackedPreview != nil || ignoredPreview != nil
    }
}

struct WorktreeCleanupUntrackedPreview: Equatable {
    let items: [String]
    let totalCount: Int
    private let sourcePathSignature: [String]

    var remainingCount: Int {
        max(totalCount - items.count, 0)
    }

    var decisionEvidenceText: String {
        var evidenceItems = items
        if remainingCount > 0 {
            evidenceItems.append("and \(remainingCount) more")
        }
        return evidenceItems.joined(separator: ", ")
    }

    init?(paths: [String], visibleLimit: Int = 3) {
        let sourcePaths = paths
            .filter { !$0.isEmpty }
        let displayItems = Self.displayItems(from: sourcePaths)
        guard !displayItems.isEmpty else { return nil }
        self.items = Array(displayItems.prefix(visibleLimit))
        totalCount = sourcePaths.count
        sourcePathSignature = Array(Set(sourcePaths)).sorted()
    }

    private static func displayItems(from paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in paths where !path.isEmpty {
            let item = displayItem(for: path)
            if seen.insert(item).inserted {
                result.append(item)
            }
        }
        return result
    }

    private static func displayItem(for path: String) -> String {
        if path.hasSuffix("/") {
            return path
        }
        guard let slash = path.firstIndex(of: "/") else {
            return path
        }
        let firstComponent = path[..<slash]
        guard !firstComponent.isEmpty else {
            return path
        }
        return "\(firstComponent)/"
    }
}

struct WorktreeCleanupCheck: Equatable {
    enum Status: Equatable {
        case ok
        case review
        case ignored

        var label: String {
            switch self {
            case .ok: return "OK"
            case .review: return "Review"
            case .ignored: return "Ignored"
            }
        }
    }

    let label: String
    let status: Status
}

struct WorktreeForceRemovalOffer: Equatable {
    let candidate: WorktreeCleanupCandidate
    let failure: GitCommandResult
}

enum WorktreeRemovalConfirmation: Identifiable, Equatable {
    case reviewWarning(WorktreeCleanupCandidate)
    case final(WorktreeCleanupCandidate)
    case force(WorktreeForceRemovalOffer)

    var id: String {
        switch self {
        case .reviewWarning(let candidate):
            return "review-warning-\(candidate.id)"
        case .final(let candidate):
            return "final-\(candidate.id)"
        case .force(let offer):
            return "force-\(offer.candidate.id)"
        }
    }

    var candidate: WorktreeCleanupCandidate {
        switch self {
        case .reviewWarning(let candidate), .final(let candidate):
            return candidate
        case .force(let offer):
            return offer.candidate
        }
    }

    var title: String {
        switch self {
        case .reviewWarning:
            return "Review Worktree?"
        case .final:
            return "Remove Worktree?"
        case .force:
            return "Force Remove Worktree?"
        }
    }

    var message: String {
        switch self {
        case .reviewWarning:
            return "This worktree needs review. Removal uses plain git worktree remove, and Git may refuse it."
        case .final(let candidate):
            return "Runs git worktree remove for \(candidate.worktreeName). The branch is left intact."
        case .force(let offer):
            let candidate = offer.candidate
            return "Runs git worktree remove --force for \(candidate.worktreeName) at \(candidate.worktreePath) on \(candidate.branchName). "
                + "This can delete uncommitted tracked changes plus untracked or ignored files in that worktree. The branch is left intact."
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .reviewWarning:
            return "Continue"
        case .final:
            return "Remove"
        case .force:
            return "Force Remove"
        }
    }

    var confirmedReviewWarning: WorktreeRemovalConfirmation? {
        guard case .reviewWarning(let candidate) = self else { return nil }
        return .final(candidate)
    }

    static func initial(for candidate: WorktreeCleanupCandidate) -> WorktreeRemovalConfirmation {
        candidate.state.isClean ? .final(candidate) : .reviewWarning(candidate)
    }
}
