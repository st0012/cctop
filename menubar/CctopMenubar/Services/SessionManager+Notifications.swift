import Foundation
@preconcurrency import UserNotifications

struct SessionNotificationClient {
    var add: (UNNotificationRequest, @escaping (Error?) -> Void) -> Void
    var removePending: ([String]) -> Void
    var removeDelivered: ([String]) -> Void
    var removeByCctopSessionID: (String) -> Void

    init(
        add: @escaping (UNNotificationRequest, @escaping (Error?) -> Void) -> Void,
        removePending: @escaping ([String]) -> Void,
        removeDelivered: @escaping ([String]) -> Void,
        removeByCctopSessionID: @escaping (String) -> Void = { _ in }
    ) {
        self.add = add
        self.removePending = removePending
        self.removeDelivered = removeDelivered
        self.removeByCctopSessionID = removeByCctopSessionID
    }

    static func identifiers(
        belongingTo cctopSessionID: String,
        in requests: [UNNotificationRequest]
    ) -> [String] {
        guard let canonicalIdentifier = SessionIdentityPolicy.notificationRequestIdentifier(
            forCctopSessionID: cctopSessionID
        ) else { return [] }

        return requests.compactMap { request in
            guard request.identifier != canonicalIdentifier,
                  SessionIdentityPolicy.cctopSessionID(
                      matchingNotificationUserInfo: request.content.userInfo
                  ) == cctopSessionID else { return nil }
            return request.identifier
        }
    }

    static let live = SessionNotificationClient(
        add: { request, completion in
            UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
        },
        removePending: { identifiers in
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        },
        removeDelivered: { identifiers in
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        },
        removeByCctopSessionID: { cctopSessionID in
            let center = UNUserNotificationCenter.current()
            center.getPendingNotificationRequests { requests in
                center.removePendingNotificationRequests(
                    withIdentifiers: SessionNotificationClient.identifiers(belongingTo: cctopSessionID, in: requests)
                )
            }
            center.getDeliveredNotifications { notifications in
                center.removeDeliveredNotifications(
                    withIdentifiers: SessionNotificationClient.identifiers(
                        belongingTo: cctopSessionID,
                        in: notifications.map(\.request)
                    )
                )
            }
        }
    )
}

enum SessionNotificationAction: Equatable {
    case remove(cctopSessionID: String)
    case post(cctopSessionID: String)
}

struct SessionAttentionProjection {
    let userSessions: [UserSession]
    let acknowledgedSessionIDs: Set<String>
}

struct SessionTemporaryDropProjection {
    let visible: [UserSession]
    let dropped: [UserSession]
}

@MainActor
extension SessionManager {
    func publishRecentResumeTargets(_ targets: [RecentResumeTarget]) {
        if targets != recentResumeTargets {
            recentResumeTargets = targets
        }
    }

    func updateAuxiliarySessionProjections(
        dropped: [UserSession],
        acknowledgedSessionIDs: Set<String>
    ) {
        if dropped != droppedUserSessions {
            droppedUserSessions = dropped
        }
        if acknowledgedSessionIDs != self.acknowledgedSessionIDs {
            self.acknowledgedSessionIDs = acknowledgedSessionIDs
        }
    }

    func acknowledgeSession(_ identity: SessionIdentityPolicy.LogicalIdentity) {
        guard let cctopSessionID = identity.cctopSessionID,
              let current = userSessions.first(where: { $0.identity == identity }),
              current.status.needsAttention else { return }

        let oldUserSessions = userSessions
        dataSources.attentionAcknowledgements.acknowledge(
            cctopSessionID: cctopSessionID,
            session: current.displayRecord.data
        )
        let acknowledged = userSessions.map { userSession -> UserSession in
            guard userSession.identity == identity else { return userSession }
            var displayData = userSession.displayRecord.data
            displayData.status = .idle
            return userSession.replacingDisplayData(displayData)
        }
        let now = dataSources.now()
        let reordered = SessionDisplayPolicy.reconcilingOrder(
            in: acknowledged,
            preserving: oldUserSessions,
            now: now
        )
        var nextAcknowledgedSessionIDs = acknowledgedSessionIDs
        nextAcknowledgedSessionIDs.insert(cctopSessionID)
        updateAuxiliarySessionProjections(
            dropped: droppedUserSessions,
            acknowledgedSessionIDs: nextAcknowledgedSessionIDs
        )
        updateSessionProjection(
            reordered,
            displaySignature: SessionDisplayPolicy.signature(for: reordered, now: now),
            syncNotificationsFrom: oldUserSessions
        )
    }

    /// Apply user acknowledgement against hook-owned status before display-only
    /// lifecycle and timeout adjustments. This preserves the exact acknowledgement
    /// until a newer hook event while regular surfaces use a neutral idle presentation.
    func applyingAttentionAcknowledgements(
        to userSessions: [UserSession],
        inventoryComplete: Bool
    ) -> SessionAttentionProjection {
        var revisions: [String: SessionAttentionRevision] = [:]
        var lastActivities: [String: Date] = [:]
        for userSession in userSessions {
            guard let cctopSessionID = userSession.identity.cctopSessionID else { continue }
            lastActivities[cctopSessionID] = userSession.records.map(\.data.lastActivity).max()
                ?? userSession.displayRecord.data.lastActivity
            if let revision = SessionAttentionRevision(session: userSession.displayRecord.data) {
                revisions[cctopSessionID] = revision
            }
        }
        dataSources.attentionAcknowledgements.reconcile(
            currentAttentionRevisions: revisions,
            currentLastActivities: lastActivities,
            inventoryComplete: inventoryComplete
        )
        let acknowledgedRevisions = dataSources.attentionAcknowledgements.acknowledgedRevisions
        var acknowledgedSessionIDs: Set<String> = []
        let projectedUserSessions = userSessions.map { userSession in
            guard let cctopSessionID = userSession.identity.cctopSessionID,
                  let currentRevision = revisions[cctopSessionID],
                  let acknowledgedRevision = acknowledgedRevisions[cctopSessionID] else {
                return userSession
            }
            let coversCurrentRevision = acknowledgedRevision == currentRevision
                || (!inventoryComplete
                    && acknowledgedRevision.lastActivity >= currentRevision.lastActivity)
            guard coversCurrentRevision else { return userSession }
            acknowledgedSessionIDs.insert(cctopSessionID)
            var displayData = userSession.displayRecord.data
            displayData.status = .idle
            return userSession.replacingDisplayData(displayData)
        }
        return SessionAttentionProjection(
            userSessions: projectedUserSessions,
            acknowledgedSessionIDs: acknowledgedSessionIDs
        )
    }

    /// Separate exact, unchanged activity revisions from operational surfaces.
    /// The Dropped selector retains reachability; a later hook event advances
    /// `lastActivity`, expires the drop, and returns the session to normal tabs.
    func partitioningTemporaryDrops(
        to userSessions: [UserSession],
        inventoryComplete: Bool
    ) -> SessionTemporaryDropProjection {
        var revisions: [String: SessionActivityRevision] = [:]
        for userSession in userSessions {
            guard let cctopSessionID = userSession.identity.cctopSessionID else { continue }
            revisions[cctopSessionID] = SessionActivityRevision(userSession: userSession)
        }
        dataSources.temporaryDrops.reconcile(
            currentRevisions: revisions,
            inventoryComplete: inventoryComplete
        )
        let droppedRevisions = dataSources.temporaryDrops.droppedRevisions
        var visible: [UserSession] = []
        var dropped: [UserSession] = []
        for userSession in userSessions {
            guard let cctopSessionID = userSession.identity.cctopSessionID,
                  let droppedRevision = droppedRevisions[cctopSessionID],
                  let currentRevision = revisions[cctopSessionID] else {
                visible.append(userSession)
                continue
            }
            let coversCurrentRevision = droppedRevision == currentRevision
                || (!inventoryComplete
                    && droppedRevision.lastActivity >= currentRevision.lastActivity)
            guard coversCurrentRevision else {
                visible.append(userSession)
                continue
            }
            dropped.append(userSession)
        }
        return SessionTemporaryDropProjection(visible: visible, dropped: dropped)
    }

    func dropSession(_ identity: SessionIdentityPolicy.LogicalIdentity) {
        guard let cctopSessionID = identity.cctopSessionID,
              let droppedUserSession = userSessions.first(where: { $0.identity == identity }) else { return }

        dataSources.temporaryDrops.drop(
            cctopSessionID: cctopSessionID,
            userSession: droppedUserSession
        )
        dataSources.attentionAcknowledgements.remove(cctopSessionID: cctopSessionID)
        removeNotification(cctopSessionID: cctopSessionID, matching: droppedUserSession.records)
        let nextDroppedUserSessions = SessionDisplayPolicy.reconcilingOrder(
            in: droppedUserSessions + [droppedUserSession],
            preserving: droppedUserSessions,
            now: dataSources.now()
        )
        updateAuxiliarySessionProjections(
            dropped: nextDroppedUserSessions,
            acknowledgedSessionIDs: acknowledgedSessionIDs.subtracting([cctopSessionID])
        )
        updateSessionProjection(userSessions.filter { $0.identity != identity })
    }

    func restoreDroppedSession(_ identity: SessionIdentityPolicy.LogicalIdentity) {
        guard let cctopSessionID = identity.cctopSessionID,
              droppedUserSessions.contains(where: { $0.identity == identity }) else { return }
        dataSources.temporaryDrops.remove(cctopSessionID: cctopSessionID)
        loadSessions()
    }

    func hideSession(_ identity: SessionIdentityPolicy.LogicalIdentity) {
        guard let cctopSessionID = identity.cctopSessionID,
              let hiddenUserSession = (userSessions + droppedUserSessions)
                .first(where: { $0.identity == identity }) else { return }

        let hiddenRecords = hiddenUserSession.records
        let hiddenProjectPaths = Set(hiddenRecords.map {
            HistoryManager.canonicalRecentProjectPath($0.data.projectPath)
        })
        dataSources.manualSessionVisibility.hide(cctopSessionID: cctopSessionID)
        dataSources.attentionAcknowledgements.remove(cctopSessionID: cctopSessionID)
        dataSources.temporaryDrops.remove(cctopSessionID: cctopSessionID)
        recentResumeTargets.removeAll { target in
            if target.cctopSessionId == cctopSessionID { return true }
            guard case .project = target else { return false }
            return hiddenProjectPaths.contains(HistoryManager.canonicalRecentProjectPath(target.projectPath))
        }
        removeNotification(cctopSessionID: cctopSessionID, matching: hiddenRecords)
        updateAuxiliarySessionProjections(
            dropped: droppedUserSessions.filter { $0.identity != identity },
            acknowledgedSessionIDs: acknowledgedSessionIDs.subtracting([cctopSessionID])
        )
        updateSessionProjection(userSessions.filter { $0.identity != identity })
    }

    func syncTransitionNotifications(
        for newUserSessions: [UserSession],
        oldUserSessions: [UserSession]
    ) {
        for action in Self.notificationActions(
            newUserSessions: newUserSessions,
            oldUserSessions: oldUserSessions,
            notificationsEnabled: dataSources.notificationsEnabled()
        ) {
            switch action {
            case .remove(let cctopSessionID):
                let oldRecords = oldUserSessions.first {
                    $0.identity.cctopSessionID == cctopSessionID
                }?.records ?? []
                removeNotification(
                    cctopSessionID: cctopSessionID,
                    matching: oldRecords
                )
            case .post(let cctopSessionID):
                sendNotification(forCctopSessionID: cctopSessionID)
            }
        }
    }

    nonisolated static func notificationActions(
        newUserSessions: [UserSession],
        oldUserSessions: [UserSession],
        notificationsEnabled: Bool
    ) -> [SessionNotificationAction] {
        let newByCctopSessionID: [String: UserSession] = Dictionary(
            newUserSessions.compactMap { userSession in
                userSession.identity.cctopSessionID.map { ($0, userSession) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let oldByCctopSessionID: [String: UserSession] = Dictionary(
            oldUserSessions.compactMap { userSession in
                userSession.identity.cctopSessionID.map { ($0, userSession) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        var actions: [SessionNotificationAction] = []
        for oldUserSession in oldUserSessions
        where oldUserSession.displayRecord.data.shouldPostAttentionNotification {
            guard let cctopSessionID = oldUserSession.identity.cctopSessionID else { continue }
            guard let newData = newByCctopSessionID[cctopSessionID]?.displayRecord.data,
                  newData.lifecycle == .active,
                  newData.shouldPostAttentionNotification else {
                actions.append(.remove(cctopSessionID: cctopSessionID))
                continue
            }
        }

        guard notificationsEnabled else { return actions }
        for newUserSession in newUserSessions {
            guard let cctopSessionID = newUserSession.identity.cctopSessionID else { continue }
            let newData = newUserSession.displayRecord.data
            guard newData.lifecycle == .active, newData.shouldPostAttentionNotification else { continue }
            guard let oldData = oldByCctopSessionID[cctopSessionID]?.displayRecord.data,
                  !oldData.shouldPostAttentionNotification else { continue }
            actions.append(.post(cctopSessionID: cctopSessionID))
        }
        return actions
    }

    nonisolated static func notificationRequest(
        forCctopSessionID cctopSessionID: String,
        displayData: SessionData
    ) -> UNNotificationRequest? {
        guard let identifier = SessionIdentityPolicy.notificationRequestIdentifier(
                  forCctopSessionID: cctopSessionID
              ),
              let userInfo = SessionIdentityPolicy.notificationUserInfo(
                  forCctopSessionID: cctopSessionID
              ) else { return nil }

        let content = UNMutableNotificationContent()
        let notification = displayData.notificationContent
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.sound = .default
        content.userInfo = userInfo

        return UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
    }

    func postNotification(forCctopSessionID cctopSessionID: String) {
        guard CctopSessionID.isValid(cctopSessionID),
              let currentUserSession = FocusTargetResolver.currentUserSession(
                  forCctopSessionID: cctopSessionID,
                  in: SessionDisplayPolicy.activeSessions(from: userSessions)
              ) else { return }
        let displayData = currentUserSession.focusTarget
        guard displayData.shouldPostAttentionNotification,
              !dataSources.manualSessionVisibility.isHidden(cctopSessionID: cctopSessionID),
              let request = Self.notificationRequest(
                  forCctopSessionID: cctopSessionID,
                  displayData: displayData
              ) else { return }

        let client = dataSources.notificationClient
        client.removePending([request.identifier])
        client.removeDelivered([request.identifier])
        client.add(request) { error in
            if let error {
                sessionManagerLogger.error("Failed to send notification: \(error, privacy: .public)")
            }
        }
    }

    private func sendNotification(forCctopSessionID cctopSessionID: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        sessionManagerLogger.error("Notification permission error: \(error, privacy: .public)")
                    }
                    if granted {
                        self.postNotification(forCctopSessionID: cctopSessionID)
                    }
                }
            case .authorized, .provisional, .ephemeral:
                self.postNotification(forCctopSessionID: cctopSessionID)
            default:
                break
            }
        }
    }

    private func removeNotification(cctopSessionID: String, matching records: [SessionRecord]) {
        guard let identifier = SessionIdentityPolicy.notificationRequestIdentifier(
            forCctopSessionID: cctopSessionID
        ) else { return }
        var identifiers = Set([identifier])
        identifiers.formUnion(
            records.compactMap {
                SessionIdentityPolicy.legacyNotificationRequestIdentifier(for: $0.data)
            }
        )
        let sortedIdentifiers = identifiers.sorted()
        let client = dataSources.notificationClient
        client.removePending(sortedIdentifiers)
        client.removeDelivered(sortedIdentifiers)
        client.removeByCctopSessionID(cctopSessionID)
    }
}
