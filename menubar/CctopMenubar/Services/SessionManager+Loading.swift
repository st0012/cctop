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
    let missingCodexDesktopThreadIDs: Int
    let codexInternalHelperThreadIDs: Int
    let uncertainCodexDelegationThreadIDs: Int
    let contradictoryCodexDelegationThreadIDs: Int
    let codexExecHelperThreadIDs: Int
    let archivedClaudeSessionIDs: Int
}

struct SessionFileCacheEntry {
    let fingerprint: SessionFileFingerprint
    let session: Session
}

struct SessionFileFingerprint: Equatable {
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let fileSize: Int64
}

extension SessionManager {
    func decodedSessions(from jsonFiles: [URL]) -> [(url: URL, session: Session)] {
        let currentPaths = Set(jsonFiles.map(\.path))
        sessionFileCache = sessionFileCache.filter { currentPaths.contains($0.key) }

        let decoded = jsonFiles.compactMap { url -> (url: URL, session: Session)? in
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
                let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: data)
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
        to candidates: [DedupCandidate],
        knownRecords: [(url: URL, session: Session)]
    ) -> [Session] {
        var records = candidates.map { (url: URL(fileURLWithPath: $0.path), session: $0.session) }
        var idsByEvidence: [String: Set<String>] = [:]
        for record in knownRecords where Session.isValidCctopSessionId(record.session.cctopSessionId) {
            guard let evidence = CctopSessionIdentityStore.durableEvidence(
                source: record.session.source,
                harnessSessionId: record.session.harnessSessionId,
                legacySessionId: record.session.sessionId
            ), let cctopSessionId = record.session.cctopSessionId else { continue }
            idsByEvidence[evidence, default: []].insert(cctopSessionId)
        }

        let identityStore = CctopSessionIdentityStore(sessionsDir: dataSources.sessionsDir)
        for index in records.indices where !Session.isValidCctopSessionId(records[index].session.cctopSessionId) {
            var session = records[index].session
            let evidence = CctopSessionIdentityStore.durableEvidence(
                source: session.source,
                harnessSessionId: session.harnessSessionId,
                legacySessionId: session.sessionId
            )
            guard let evidence else {
                scheduleRecordLocalCctopSessionIdentityStamp(
                    url: records[index].url,
                    snapshot: session
                )
                continue
            }
            let knownIDs = idsByEvidence[evidence] ?? []
            do {
                let cctopSessionId = try identityStore.resolve(
                    source: session.source,
                    harnessSessionId: session.harnessSessionId,
                    legacySessionId: session.sessionId,
                    knownExistingIDs: knownIDs
                )
                session.cctopSessionId = cctopSessionId
                records[index].session = session
                idsByEvidence[evidence, default: []].insert(cctopSessionId)
                cacheMigratedSession(session, at: records[index].url.path)
                scheduleCctopSessionIdentityStamp(
                    url: records[index].url,
                    snapshot: records[index].session
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

    private func cacheMigratedSession(_ session: Session, at path: String) {
        guard let cached = sessionFileCache[path] else { return }
        sessionFileCache[path] = SessionFileCacheEntry(
            fingerprint: cached.fingerprint,
            session: session
        )
    }

    func identifiedPublishableSessions(
        winners: [DedupCandidate],
        knownRecords: [(url: URL, session: Session)]
    ) -> [Session] {
        let publishableWinners = winners.filter { $0.session.lifecycle != .finished }
        return assigningCctopSessionIdentities(to: publishableWinners, knownRecords: knownRecords)
    }

    func identifyingRecentDesktopRecords(
        in classification: SessionClassificationSnapshot,
        knownRecords: [(url: URL, session: Session)]
    ) -> SessionClassificationSnapshot {
        let indices = classification.records.indices.filter { index in
            let record = classification.records[index]
            guard !Session.isValidCctopSessionId(record.candidate.session.cctopSessionId),
                  case .hidden(let reason) = record.disposition else { return false }
            switch reason {
            case .archivedCodexDesktop, .archivedClaudeDesktop:
                return CctopSessionIdentityStore.durableEvidence(
                    source: record.candidate.session.source,
                    harnessSessionId: record.candidate.session.harnessSessionId,
                    legacySessionId: record.candidate.session.sessionId
                ) != nil
            case .persistedHidden, .autoHidden, .missingCodexDesktopThread, .codexInternalHelper, .codexExecHelper,
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
        for (index, session) in zip(indices, identified) {
            let record = records[index]
            let candidate = record.candidate
            records[index] = ClassifiedSessionRecord(
                url: record.url,
                candidate: DedupCandidate(
                    session: session,
                    lifecycleRank: candidate.lifecycleRank,
                    mtime: candidate.mtime,
                    path: candidate.path
                ),
                disposition: record.disposition
            )
        }
        return SessionClassificationSnapshot(records: records, evidence: classification.evidence)
    }

    private func scheduleRecordLocalCctopSessionIdentityStamp(url: URL, snapshot: Session) {
        guard pendingIdentityMigrationPaths.insert(url.path).inserted else { return }
        cctopIdentityMigrationQueue.async { [weak self] in
            do {
                _ = try withSessionLockIfAvailable(sessionPath: url.path) {
                    guard var current = try? Session.fromFile(path: url.path),
                          !Session.isValidCctopSessionId(current.cctopSessionId),
                          current.sessionId == snapshot.sessionId,
                          current.source == snapshot.source,
                          current.harnessSessionId == snapshot.harnessSessionId else { return }
                    current.cctopSessionId = Session.makeCctopSessionId()
                    try current.writeToFile(path: url.path)
                }
            } catch {
                let fileName = url.lastPathComponent
                let reason = error.localizedDescription
                sessionManagerLogger.warning(
                    "record-local identity stamp failed for \(fileName, privacy: .public): \(reason, privacy: .public)"
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingIdentityMigrationPaths.remove(url.path)
                self.sessionFileCache.removeValue(forKey: url.path)
            }
        }
    }

    private func scheduleCctopSessionIdentityStamp(url: URL, snapshot: Session) {
        guard let cctopSessionId = snapshot.cctopSessionId,
              pendingIdentityMigrationPaths.insert(url.path).inserted else { return }
        cctopIdentityMigrationQueue.async { [weak self] in
            do {
                _ = try withSessionLockIfAvailable(sessionPath: url.path) {
                    guard var current = try? Session.fromFile(path: url.path) else { return }
                    if Session.isValidCctopSessionId(current.cctopSessionId) {
                        return
                    }
                    guard current.sessionId == snapshot.sessionId,
                          current.source == snapshot.source,
                          current.harnessSessionId == snapshot.harnessSessionId else { return }
                    current.cctopSessionId = cctopSessionId
                    try current.writeToFile(path: url.path)
                }
            } catch {
                let fileName = url.lastPathComponent
                let reason = error.localizedDescription
                sessionManagerLogger.warning(
                    "identity stamp failed for \(fileName, privacy: .public): \(reason, privacy: .public)"
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

    func currentStatusesByStableKey() -> [String: SessionStatus] {
        Dictionary(
            sessions.map { (SessionIdentityPolicy.stableKey(for: $0), $0.status) },
            uniquingKeysWith: { first, _ in first }
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
            missingCodexDesktopThreadIDs: classification.missingCodexDesktopThreadIDs.count,
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
        sessionManagerLogger.info("loadSessions: \(classification.missingCodexDesktopThreadIDs.count) codex-missing-state")
        sessionManagerLogger.info("loadSessions: \(classification.codexInternalHelperThreadIDs.count) codex-internal-helper")
        sessionManagerLogger.info("loadSessions: \(classification.uncertainCodexDelegationThreadIDs.count) codex-source-uncertain")
        sessionManagerLogger.info(
            "loadSessions: \(classification.contradictoryCodexDelegationThreadIDs.count) codex-source-contradictory"
        )
        sessionManagerLogger.info("loadSessions: \(classification.codexExecHelperThreadIDs.count) codex-exec-helper")
        sessionManagerLogger.info("loadSessions: \(classification.archivedClaudeSessionIDs.count) claude-archived")
    }
}
