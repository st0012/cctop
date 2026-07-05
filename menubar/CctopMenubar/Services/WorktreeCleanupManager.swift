import Foundation
import os.log

private let worktreeCleanupLogger = Logger(
    subsystem: "com.st0012.CctopMenubar",
    category: "WorktreeCleanupManager"
)

@MainActor
class WorktreeCleanupManager: ObservableObject {
    @Published var candidates: [WorktreeCleanupCandidate] = []
    @Published private(set) var isScanning = false

    fileprivate let scanner: WorktreeCleanupScanner
    private var refreshGeneration = 0
    private var lastRefreshSignature: WorktreeCleanupRefreshSignature?

    init(scanner: WorktreeCleanupScanner = .live()) {
        self.scanner = scanner
    }

    func refresh(
        from cleanupSources: [SessionCleanupSource],
        activeProjectPaths: Set<String>,
        force: Bool = false,
        onCompletion: (([WorktreeCleanupCandidate]) -> Void)? = nil
    ) {
        let signature = WorktreeCleanupRefreshSignature(
            cleanupSources: cleanupSources,
            activeProjectPaths: activeProjectPaths
        )
        guard force || signature != lastRefreshSignature else { return }
        lastRefreshSignature = signature

        refreshGeneration += 1
        let generation = refreshGeneration
        let scanner = scanner
        isScanning = true
        DispatchQueue.global(qos: .utility).async {
            let next = scanner
                .candidates(from: cleanupSources, activeProjectPaths: activeProjectPaths)
                .filter(\.state.isActionable)
            DispatchQueue.main.async {
                guard generation == self.refreshGeneration else { return }
                self.isScanning = false
                if next != self.candidates {
                    worktreeCleanupLogger.info("cleanup candidates \(self.candidates.count) -> \(next.count)")
                    self.candidates = next
                }
                onCompletion?(next)
            }
        }
    }
}

@MainActor
final class WorktreeCleanupRefreshGate: ObservableObject {
    @Published private(set) var hasHiddenCleanupNudge = false

    private let manager: WorktreeCleanupManager
    private var cleanupSources: [SessionCleanupSource] = []
    private var activeProjectPaths: Set<String> = []
    private var isCleanupTabSelected = false
    private var isPanelVisible = false
    private var isCleanupVisible = false
    private var seenCleanupCandidateIDs: Set<String> = []

    init(manager: WorktreeCleanupManager) {
        self.manager = manager
    }

    func updateSources(_ cleanupSources: [SessionCleanupSource], activeProjectPaths: Set<String>) {
        self.cleanupSources = cleanupSources
        self.activeProjectPaths = activeProjectPaths
        if isCleanupVisible {
            refreshIfVisible()
        } else {
            refreshWhileHidden()
        }
    }

    func setCleanupVisible(_ visible: Bool) {
        isCleanupTabSelected = visible
        isPanelVisible = visible
        updateCleanupVisibility(forceRefreshWhenVisible: visible)
    }

    func setCleanupTabSelected(_ selected: Bool) {
        isCleanupTabSelected = selected
        updateCleanupVisibility()
    }

    func setPanelVisible(_ visible: Bool) {
        isPanelVisible = visible
        updateCleanupVisibility()
    }

    func refreshIfVisible(force: Bool = false) {
        guard isCleanupVisible else { return }
        markCurrentCandidatesSeen()
        manager.refresh(from: cleanupSources, activeProjectPaths: activeProjectPaths, force: force) { [weak self] candidates in
            guard let self, self.isCleanupVisible else { return }
            self.markCandidatesSeen(candidates)
        }
    }

    private func updateCleanupVisibility(forceRefreshWhenVisible: Bool = false) {
        let visible = isCleanupTabSelected && isPanelVisible
        guard visible != isCleanupVisible || (visible && forceRefreshWhenVisible) else { return }
        isCleanupVisible = visible
        if visible {
            refreshIfVisible(force: true)
        }
    }

    private func refreshWhileHidden() {
        manager.refresh(from: cleanupSources, activeProjectPaths: activeProjectPaths) { [weak self] candidates in
            guard let self else { return }
            if self.isCleanupVisible {
                self.markCandidatesSeen(candidates)
            } else {
                self.updateHiddenNudge(from: candidates)
            }
        }
    }

    private func updateHiddenNudge(from candidates: [WorktreeCleanupCandidate]) {
        let candidateIDs = Set(candidates.map(\.id))
        if candidateIDs.isEmpty {
            hasHiddenCleanupNudge = false
            seenCleanupCandidateIDs = []
        } else {
            hasHiddenCleanupNudge = !candidateIDs.subtracting(seenCleanupCandidateIDs).isEmpty
        }
    }

    private func markCurrentCandidatesSeen() {
        markCandidatesSeen(manager.candidates)
    }

    private func markCandidatesSeen(_ candidates: [WorktreeCleanupCandidate]) {
        seenCleanupCandidateIDs = Set(candidates.map(\.id))
        hasHiddenCleanupNudge = false
    }
}

struct WorktreeCleanupRefreshSignature: Equatable {
    private struct CleanupSourceFingerprint: Equatable {
        let path: String
        let sessionId: String
        let lastActiveAt: Date
        let displayName: String
        let branch: String
    }

    private let cleanupSources: [CleanupSourceFingerprint]
    private let activeProjectPaths: [String]

    init(cleanupSources: [SessionCleanupSource], activeProjectPaths: Set<String>) {
        self.cleanupSources = cleanupSources
            .compactMap {
                let path = WorktreeCleanupScanner.standardizedPath($0.projectPath)
                guard WorktreeCleanupScanner.shouldScanCleanupSourcePath(path) else { return nil }
                return CleanupSourceFingerprint(
                    path: path,
                    sessionId: $0.sessionId,
                    lastActiveAt: $0.lastActiveAt,
                    displayName: $0.sessionName,
                    branch: $0.branch
                )
            }
            .sorted { lhs, rhs in
                if lhs.path != rhs.path { return lhs.path < rhs.path }
                if lhs.lastActiveAt != rhs.lastActiveAt { return lhs.lastActiveAt < rhs.lastActiveAt }
                if lhs.sessionId != rhs.sessionId { return lhs.sessionId < rhs.sessionId }
                if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
                return lhs.branch < rhs.branch
            }
        self.activeProjectPaths = activeProjectPaths
            .map(WorktreeCleanupScanner.standardizedPath)
            .sorted()
    }
}
