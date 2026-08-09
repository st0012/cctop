import Darwin
import Foundation

private let cctopIdentityMigrationQueue = DispatchQueue(
    label: "com.st0012.CctopMenubar.SessionIdentityMigration",
    qos: .utility
)

struct SessionLoadSummary: Equatable {
    let files: Int
    let decoded: Int
    let live: Int
    let hidden: Int
    let autoHidden: Int
}

struct SessionLoadLogSignature: Equatable {
    let summary: SessionLoadSummary
    let archivedCodexThreadIDs: Int
    let missingCodexThreadIDs: Int
    let codexInternalHelperThreadIDs: Int
    let uncertainCodexDelegationThreadIDs: Int
    let contradictoryCodexDelegationThreadIDs: Int
    let codexExecHelperThreadIDs: Int
    let archivedClaudeSessionIDs: Int
}

struct SessionFileCacheEntry {
    let fingerprint: SessionFileFingerprint
    let session: SessionData
}

struct SessionFileFingerprint: Equatable {
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let fileSize: Int64
}

extension SessionManager {
    func decodedSessions(from jsonFiles: [URL]) -> [(url: URL, session: SessionData)] {
        let currentPaths = Set(jsonFiles.map(\.path))
        sessionFileCache = sessionFileCache.filter { currentPaths.contains($0.key) }

        let decoded = jsonFiles.compactMap { url -> (url: URL, session: SessionData)? in
            guard let fingerprint = sessionFileFingerprint(for: url) else {
                sessionFileCache.removeValue(forKey: url.path)
                sessionManagerLogger.warning("loadSessions: could not stat \(url.lastPathComponent, privacy: .public)")
                return nil
            }
            if let cached = sessionFileCache[url.path], cached.fingerprint == fingerprint {
                return (url, cached.session)
            }
            guard let data = try? Data(contentsOf: url) else {
                sessionFileCache.removeValue(forKey: url.path)
                sessionManagerLogger.warning("loadSessions: could not read \(url.lastPathComponent, privacy: .public)")
                return nil
            }
            do {
                let session = try JSONDecoder.sessionDecoder.decode(SessionData.self, from: data)
                sessionFileCache[url.path] = SessionFileCacheEntry(
                    fingerprint: fingerprint,
                    session: session
                )
                return (url, session)
            } catch {
                sessionFileCache.removeValue(forKey: url.path)
                sessionManagerLogger.error("loadSessions: decode failed \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                return nil
            }
        }
        return decoded
    }

    // Build one evidence index and resolve the bounded publishable set in a single pass.
    func assigningCctopSessionIdentities(
        to candidates: [SessionRecord],
        knownRecords: [(url: URL, session: SessionData)]
    ) -> [SessionData] {
        var records = candidates.map { (url: URL(fileURLWithPath: $0.path), session: $0.data) }
        var idsByEvidence: [String: Set<String>] = [:]
        for record in knownRecords where CctopSessionID.isValid(record.session.cctopSessionId) {
            guard let evidence = CctopSessionIdentityStore.durableEvidence(for: record.session),
                  let cctopSessionId = record.session.cctopSessionId else { continue }
            idsByEvidence[evidence, default: []].insert(cctopSessionId)
        }

        let identityStore = CctopSessionIdentityStore(sessionsDir: dataSources.sessionsDir)
        for index in records.indices where !CctopSessionID.isValid(records[index].session.cctopSessionId) {
            var data = records[index].session
            guard let evidence = CctopSessionIdentityStore.durableEvidence(for: data) else {
                scheduleCctopSessionIdentityStamp(
                    url: records[index].url,
                    snapshot: data,
                    resolvedID: nil
                )
                continue
            }
            let knownIDs = idsByEvidence[evidence] ?? []
            do {
                let cctopSessionId = try identityStore.resolve(
                    source: data.source,
                    harnessSessionId: data.harnessSessionId,
                    legacySessionId: data.sessionId,
                    knownExistingIDs: knownIDs
                )
                data.cctopSessionId = cctopSessionId
                records[index].session = data
                idsByEvidence[evidence, default: []].insert(cctopSessionId)
                scheduleCctopSessionIdentityStamp(
                    url: records[index].url,
                    snapshot: records[index].session,
                    resolvedID: cctopSessionId
                )
            } catch {
                let fileName = records[index].url.lastPathComponent
                let reason = error.localizedDescription
                sessionManagerLogger.error(
                    "loadSessions: identity migration failed for \(fileName, privacy: .public): \(reason, privacy: .public)"
                )
            }
        }
        return records.map(\.session)
    }

    func identifiedPublishableCandidates(
        winners: [SessionRecord],
        knownRecords: [(url: URL, session: SessionData)]
    ) -> [SessionRecord] {
        let publishableWinners = winners.filter { $0.data.lifecycle != .finished }
        let identified = assigningCctopSessionIdentities(to: publishableWinners, knownRecords: knownRecords)
        return zip(publishableWinners, identified).map { candidate, data in
            SessionRecord(
                data: data,
                lifecycleRank: candidate.lifecycleRank,
                mtime: candidate.mtime,
                path: candidate.path
            )
        }
    }

    func identifyingPersistedRecords(
        in classification: SessionClassificationSnapshot,
        knownRecords: [(url: URL, session: SessionData)]
    ) -> SessionClassificationSnapshot {
        let legacyKeys = dataSources.manualSessionVisibility.unresolvedDurableLegacyKeys
        let indices = classification.records.indices.filter { index in
            let record = classification.records[index]
            let data = record.candidate.data
            guard case .legacy(let stableKey) = SessionIdentityPolicy.logicalIdentity(for: data) else { return false }
            if hasExistingMappedManualHide(data) { return true }
            if legacyKeys.contains(stableKey) { return true }
            guard case .hidden(let reason) = record.disposition else { return false }
            switch reason {
            case .archivedClaudeDesktop:
                return CctopSessionIdentityStore.durableEvidence(for: data) != nil
            case .persistedHidden, .autoHidden, .archivedCodexThread, .missingCodexThread,
                 .codexInternalHelper, .codexExecHelper,
                 .orphanedEndedClaudeDesktop, .claudeDesktopStartupPlaceholder:
                return false
            }
        }
        guard !indices.isEmpty else { return classification }

        let identified = assigningCctopSessionIdentities(
            to: indices.map { classification.records[$0].candidate },
            knownRecords: knownRecords
        )
        var records = classification.records
        for (index, data) in zip(indices, identified) {
            let record = records[index]
            let candidate = record.candidate
            records[index] = ClassifiedSessionRecord(
                url: record.url,
                candidate: SessionRecord(
                    data: data,
                    lifecycleRank: candidate.lifecycleRank,
                    mtime: candidate.mtime,
                    path: candidate.path
                ),
                disposition: record.disposition
            )
        }
        return SessionClassificationSnapshot(records: records, evidence: classification.evidence)
    }

    private func scheduleCctopSessionIdentityStamp(
        url: URL,
        snapshot: SessionData,
        resolvedID: String?
    ) {
        guard pendingIdentityMigrationPaths.insert(url.path).inserted else { return }
        cctopIdentityMigrationQueue.async { [weak self] in
            do {
                _ = try withSessionLockIfAvailable(sessionPath: url.path) {
                    guard var current = try? SessionData.fromFile(path: url.path) else { return }
                    if CctopSessionID.isValid(current.cctopSessionId) {
                        return
                    }
                    guard current.sessionId == snapshot.sessionId,
                          current.source == snapshot.source,
                          current.harnessSessionId == snapshot.harnessSessionId else { return }
                    current.cctopSessionId = resolvedID ?? CctopSessionID.make()
                    try current.writeToFile(path: url.path)
                }
            } catch {
                let fileName = url.lastPathComponent
                let reason = error.localizedDescription
                let prefix = resolvedID == nil ? "record-local identity stamp" : "identity stamp"
                sessionManagerLogger.warning(
                    "\(prefix, privacy: .public) failed for \(fileName, privacy: .public): \(reason, privacy: .public)"
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingIdentityMigrationPaths.remove(url.path)
                self.sessionFileCache.removeValue(forKey: url.path)
            }
        }
    }

    private func sessionFileFingerprint(for url: URL) -> SessionFileFingerprint? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return SessionFileFingerprint(
            modifiedSeconds: Int(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec),
            fileSize: Int64(info.st_size)
        )
    }

    func sessionJSONFiles(in files: [URL]) -> [URL] {
        files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".tmp") }
    }

    /// A pre-PID session file was keyed by a bare session UUID. Today's files are either
    /// numeric (PID) or `codex-<uuid>`, so only genuinely old files match.
    nonisolated static func isLegacyUUIDFilename(_ stem: String) -> Bool {
        HostApp.isUUID(stem)
    }

    func logLoadSummary(_ summary: SessionLoadSummary, classification: SessionClassificationSnapshot) {
        let signature = SessionLoadLogSignature(
            summary: summary,
            archivedCodexThreadIDs: classification.archivedCodexThreadIDs.count,
            missingCodexThreadIDs: classification.missingCodexThreadIDs.count,
            codexInternalHelperThreadIDs: classification.codexInternalHelperThreadIDs.count,
            uncertainCodexDelegationThreadIDs: classification.uncertainCodexDelegationThreadIDs.count,
            contradictoryCodexDelegationThreadIDs: classification.contradictoryCodexDelegationThreadIDs.count,
            codexExecHelperThreadIDs: classification.codexExecHelperThreadIDs.count,
            archivedClaudeSessionIDs: classification.archivedClaudeSessionIDs.count
        )
        guard signature != lastLoadLogSignature else { return }
        lastLoadLogSignature = signature

        sessionManagerLogger.info("loadSessions: \(summary.files) files, \(summary.decoded) decoded")
        sessionManagerLogger.info(
            "loadSessions: \(summary.live) visible candidates, \(summary.hidden) hidden, \(summary.autoHidden) auto-hidden"
        )
        sessionManagerLogger.info("loadSessions: \(classification.archivedCodexThreadIDs.count) codex-archived")
        sessionManagerLogger.info("loadSessions: \(classification.missingCodexThreadIDs.count) codex-missing-state")
        sessionManagerLogger.info("loadSessions: \(classification.codexInternalHelperThreadIDs.count) codex-internal-helper")
        sessionManagerLogger.info("loadSessions: \(classification.uncertainCodexDelegationThreadIDs.count) codex-source-uncertain")
        sessionManagerLogger.info(
            "loadSessions: \(classification.contradictoryCodexDelegationThreadIDs.count) codex-source-contradictory"
        )
        sessionManagerLogger.info("loadSessions: \(classification.codexExecHelperThreadIDs.count) codex-exec-helper")
        sessionManagerLogger.info("loadSessions: \(classification.archivedClaudeSessionIDs.count) claude-archived")
    }
}
