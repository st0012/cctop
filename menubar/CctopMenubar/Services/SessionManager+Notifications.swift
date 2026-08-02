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
    case post(session: Session)
}

@MainActor
extension SessionManager {
    func hideSession(_ session: Session) {
        guard let cctopSessionID = session.cctopSessionId,
              Session.isValidCctopSessionId(cctopSessionID),
              sessions.contains(where: { $0.cctopSessionId == cctopSessionID }) else { return }

        let hiddenSessions = sessions.filter { $0.cctopSessionId == cctopSessionID }
        let hiddenProjectPaths = Set(hiddenSessions.map { HistoryManager.canonicalRecentProjectPath($0.projectPath) })
        dataSources.manualSessionVisibility.hide(session)
        let visibleSessions = sessions.filter { $0.cctopSessionId != cctopSessionID }
        recentResumeTargets.removeAll { target in
            if target.cctopSessionId == cctopSessionID { return true }
            guard case .project = target else { return false }
            return hiddenProjectPaths.contains(HistoryManager.canonicalRecentProjectPath(target.projectPath))
        }
        removeNotification(cctopSessionID: cctopSessionID, matching: hiddenSessions)
        sessions = visibleSessions
    }

    func isManuallyHidden(_ session: Session) -> Bool {
        dataSources.manualSessionVisibility.isHidden(session)
    }

    func syncTransitionNotifications(for newSessions: [Session], oldSessions: [Session]) {
        for action in Self.notificationActions(
            newSessions: newSessions,
            oldSessions: oldSessions,
            notificationsEnabled: dataSources.notificationsEnabled()
        ) {
            switch action {
            case .remove(let cctopSessionID):
                removeNotification(cctopSessionID: cctopSessionID, matching: oldSessions)
            case .post(let session):
                sendNotification(for: session)
            }
        }
    }

    nonisolated static func notificationActions(
        newSessions: [Session],
        oldSessions: [Session],
        notificationsEnabled: Bool
    ) -> [SessionNotificationAction] {
        let newByCctopSessionID: [String: Session] = Dictionary(
            newSessions.compactMap { session in
                SessionIdentityPolicy.permanentSessionID(for: session).map { ($0, session) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let oldByCctopSessionID: [String: Session] = Dictionary(
            oldSessions.compactMap { session in
                SessionIdentityPolicy.permanentSessionID(for: session).map { ($0, session) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        var actions: [SessionNotificationAction] = []
        for (cctopSessionID, oldSession) in oldByCctopSessionID where oldSession.shouldPostAttentionNotification {
            guard let newSession = newByCctopSessionID[cctopSessionID],
                  newSession.lifecycle == .active,
                  newSession.shouldPostAttentionNotification else {
                actions.append(.remove(cctopSessionID: cctopSessionID))
                continue
            }
        }

        guard notificationsEnabled else { return actions }
        for (cctopSessionID, newSession) in newByCctopSessionID
        where newSession.lifecycle == .active && newSession.shouldPostAttentionNotification {
            guard let oldSession = oldByCctopSessionID[cctopSessionID],
                  !oldSession.shouldPostAttentionNotification else { continue }
            actions.append(.post(session: newSession))
        }
        return actions
    }

    nonisolated static func notificationRequest(for session: Session) -> UNNotificationRequest? {
        guard let cctopSessionID = SessionIdentityPolicy.permanentSessionID(for: session),
              let identifier = SessionIdentityPolicy.notificationRequestIdentifier(
                  forCctopSessionID: cctopSessionID
              ),
              let userInfo = SessionIdentityPolicy.notificationUserInfo(
                  forCctopSessionID: cctopSessionID
              ) else { return nil }

        let content = UNMutableNotificationContent()
        let notification = session.notificationContent
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

    func postNotification(for session: Session) {
        guard let cctopSessionID = SessionIdentityPolicy.permanentSessionID(for: session),
              let currentSession = FocusTargetResolver.currentSession(
                  forCctopSessionID: cctopSessionID,
                  in: SessionDisplayPolicy.activeSessions(from: sessions)
              ),
              currentSession.shouldPostAttentionNotification,
              !isManuallyHidden(currentSession),
              let request = Self.notificationRequest(for: currentSession) else { return }

        let client = dataSources.notificationClient
        client.removePending([request.identifier])
        client.removeDelivered([request.identifier])
        client.add(request) { error in
            if let error {
                sessionManagerLogger.error("Failed to send notification: \(error, privacy: .public)")
            }
        }
    }

    private func sendNotification(for session: Session) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        sessionManagerLogger.error("Notification permission error: \(error, privacy: .public)")
                    }
                    if granted {
                        self.postNotification(for: session)
                    }
                }
            case .authorized, .provisional, .ephemeral:
                self.postNotification(for: session)
            default:
                break
            }
        }
    }

    private func removeNotification(cctopSessionID: String, matching observations: [Session]) {
        guard let identifier = SessionIdentityPolicy.notificationRequestIdentifier(
            forCctopSessionID: cctopSessionID
        ) else { return }
        var identifiers = Set([identifier])
        identifiers.formUnion(
            observations
                .filter { $0.cctopSessionId == cctopSessionID }
                .compactMap(SessionIdentityPolicy.legacyNotificationRequestIdentifier)
        )
        let sortedIdentifiers = identifiers.sorted()
        let client = dataSources.notificationClient
        client.removePending(sortedIdentifiers)
        client.removeDelivered(sortedIdentifiers)
        client.removeByCctopSessionID(cctopSessionID)
    }
}
