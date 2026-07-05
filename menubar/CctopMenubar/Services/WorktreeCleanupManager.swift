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
        force: Bool = false
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
    private var seenCleanupSourceIDs: Set<WorktreeCleanupSourceIdentity> = []

    init(manager: WorktreeCleanupManager) {
        self.manager = manager
    }

    func updateSources(_ cleanupSources: [SessionCleanupSource], activeProjectPaths: Set<String>) {
        self.cleanupSources = cleanupSources
        self.activeProjectPaths = activeProjectPaths
        if isCleanupVisible {
            refreshIfVisible()
        } else {
            updateHiddenNudgeFromSourceIdentities()
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
        markCurrentSourcesSeen()
        manager.refresh(from: cleanupSources, activeProjectPaths: activeProjectPaths, force: force)
    }

    private func updateCleanupVisibility(forceRefreshWhenVisible: Bool = false) {
        let visible = isCleanupTabSelected && isPanelVisible
        guard visible != isCleanupVisible || (visible && forceRefreshWhenVisible) else { return }
        isCleanupVisible = visible
        if visible {
            refreshIfVisible(force: true)
        }
    }

    private func updateHiddenNudgeFromSourceIdentities() {
        let sourceIDs = currentSourceIDs()
        if sourceIDs.isEmpty {
            hasHiddenCleanupNudge = false
            seenCleanupSourceIDs = []
        } else {
            hasHiddenCleanupNudge = !sourceIDs.subtracting(seenCleanupSourceIDs).isEmpty
        }
    }

    private func markCurrentSourcesSeen() {
        seenCleanupSourceIDs = currentSourceIDs()
        hasHiddenCleanupNudge = false
    }

    private func currentSourceIDs() -> Set<WorktreeCleanupSourceIdentity> {
        let activePaths = Set(activeProjectPaths.map(WorktreeCleanupScanner.standardizedPath))
        return Set(cleanupSources.compactMap { source in
            WorktreeCleanupSourceIdentity(source: source, activeProjectPaths: activePaths, scanner: manager.scanner)
        })
    }
}

private struct WorktreeCleanupSourceIdentity: Hashable {
    let path: String
    let sessionId: String

    init?(source: SessionCleanupSource, activeProjectPaths: Set<String>, scanner: WorktreeCleanupScanner) {
        guard let path = scanner.hiddenCleanupSourceIdentityPath(for: source.projectPath) else { return nil }
        guard !Self.isActive(path, activeProjectPaths: activeProjectPaths) else { return nil }
        self.path = path
        sessionId = source.sessionId
    }

    private static func isActive(_ path: String, activeProjectPaths: Set<String>) -> Bool {
        if WorktreeCleanupScanner.isCleanupSourcePathActive(path, activeProjectPaths: activeProjectPaths) {
            return true
        }
        guard let cleanupRoot = cleanupWorktreePrefix(for: path) else { return false }
        return activeProjectPaths.contains { activePath in
            cleanupWorktreePrefix(for: activePath) == cleanupRoot
        }
    }

    private static func cleanupWorktreePrefix(for path: String) -> String? {
        let components = URL(fileURLWithPath: WorktreeCleanupScanner.standardizedPath(path)).pathComponents
        guard components.count >= 3 else { return nil }
        for index in 0..<(components.count - 2) {
            let marker = components[index]
            guard marker == ".claude" || marker == ".codex",
                  components[index + 1] == "worktrees",
                  !components[index + 2].isEmpty else {
                continue
            }
            return prefixPath(from: components.prefix(index + 3))
        }
        return nil
    }

    private static func prefixPath(from components: ArraySlice<String>) -> String {
        if components.first == "/" {
            return "/" + components.dropFirst().joined(separator: "/")
        }
        return components.joined(separator: "/")
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
