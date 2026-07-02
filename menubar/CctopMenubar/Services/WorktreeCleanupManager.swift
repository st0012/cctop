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

    private let scanner: WorktreeCleanupScanner
    private var refreshGeneration = 0
    private var lastRefreshSignature: WorktreeCleanupRefreshSignature?

    init(scanner: WorktreeCleanupScanner = .live()) {
        self.scanner = scanner
    }

    func refresh(from cleanupSources: [SessionCleanupSource], activeProjectPaths: Set<String>, force: Bool = false) {
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
            }
        }
    }
}

@MainActor
final class WorktreeCleanupRefreshGate {
    private let manager: WorktreeCleanupManager
    private var cleanupSources: [SessionCleanupSource] = []
    private var activeProjectPaths: Set<String> = []
    private var isCleanupVisible = false

    init(manager: WorktreeCleanupManager) {
        self.manager = manager
    }

    func updateSources(_ cleanupSources: [SessionCleanupSource], activeProjectPaths: Set<String>) {
        self.cleanupSources = cleanupSources
        self.activeProjectPaths = activeProjectPaths
        refreshIfVisible()
    }

    func setCleanupVisible(_ visible: Bool) {
        isCleanupVisible = visible
        if visible {
            refreshIfVisible(force: true)
        }
    }

    func refreshIfVisible(force: Bool = false) {
        guard isCleanupVisible else { return }
        manager.refresh(from: cleanupSources, activeProjectPaths: activeProjectPaths, force: force)
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
            .map {
                CleanupSourceFingerprint(
                    path: WorktreeCleanupScanner.standardizedPath($0.projectPath),
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
