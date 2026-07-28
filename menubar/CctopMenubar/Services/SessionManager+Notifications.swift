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
        requests.compactMap { request in
            SessionIdentityPolicy.cctopSessionID(matchingNotificationUserInfo: request.content.userInfo) == cctopSessionID
                ? request.identifier
                : nil
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
    case remove(identifier: String)
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
        let notificationIdentifiers = Set(
            hiddenSessions.map(SessionIdentityPolicy.notificationRequestIdentifier)
        ).sorted()
        dataSources.manualSessionVisibility.hide(session)
        let visibleSessions = sessions.filter { $0.cctopSessionId != cctopSessionID }
        recentResumeTargets.removeAll { target in
            if target.cctopSessionId == cctopSessionID { return true }
            guard case .project = target else { return false }
            return hiddenProjectPaths.contains(HistoryManager.canonicalRecentProjectPath(target.projectPath))
        }
        dataSources.notificationClient.removePending(notificationIdentifiers)
        dataSources.notificationClient.removeDelivered(notificationIdentifiers)
        dataSources.notificationClient.removeByCctopSessionID(cctopSessionID)
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
            case .remove(let identifier):
                removeNotification(identifier: identifier)
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
        let newByStableKey = Dictionary(
            newSessions.map { (SessionIdentityPolicy.stableKey(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let oldByStableKey = Dictionary(
            oldSessions.map { (SessionIdentityPolicy.stableKey(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var actions: [SessionNotificationAction] = []
        for (key, oldSession) in oldByStableKey where oldSession.shouldPostAttentionNotification {
            guard let newSession = newByStableKey[key],
                  newSession.lifecycle == .active,
                  newSession.shouldPostAttentionNotification else {
                actions.append(.remove(identifier: SessionIdentityPolicy.notificationRequestIdentifier(for: oldSession)))
                continue
            }
        }

        guard notificationsEnabled else { return actions }
        for (key, newSession) in newByStableKey where newSession.lifecycle == .active && newSession.shouldPostAttentionNotification {
            guard let oldSession = oldByStableKey[key],
                  !oldSession.shouldPostAttentionNotification else { continue }
            actions.append(.post(session: newSession))
        }
        return actions
    }

    nonisolated static func notificationRequest(for session: Session) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        let notification = session.notificationContent
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.sound = .default
        content.userInfo = SessionIdentityPolicy.notificationUserInfo(for: session)

        return UNNotificationRequest(
            identifier: SessionIdentityPolicy.notificationRequestIdentifier(for: session),
            content: content,
            trigger: nil
        )
    }

    func postNotification(for session: Session) {
        let currentSession: Session?
        if let cctopSessionID = session.cctopSessionId,
           Session.isValidCctopSessionId(cctopSessionID) {
            let requestIdentifier = SessionIdentityPolicy.notificationRequestIdentifier(for: session)
            let matches = sessions.filter {
                $0.cctopSessionId == cctopSessionID
                    && SessionIdentityPolicy.notificationRequestIdentifier(for: $0) == requestIdentifier
            }
            currentSession = matches.count == 1 ? matches[0] : nil
        } else if session.cctopSessionId == nil {
            let matches = sessions.filter { current in
                guard let pendingPID = session.pid,
                      current.pid == pendingPID,
                      let pendingStart = session.pidStartTime,
                      let currentStart = current.pidStartTime,
                      abs(pendingStart - currentStart) <= 1.0,
                      (session.source ?? Session.ccSource) == (current.source ?? Session.ccSource) else {
                    return false
                }
                switch (session.harnessSessionId, current.harnessSessionId) {
                case let (pendingHarnessID?, currentHarnessID?):
                    return pendingHarnessID == currentHarnessID
                case (nil, nil):
                    return session.sessionId == current.sessionId
                default:
                    return false
                }
            }
            currentSession = matches.count == 1 ? matches[0] : nil
        } else {
            currentSession = nil
        }
        guard let currentSession,
              currentSession.lifecycle == .active,
              currentSession.shouldPostAttentionNotification,
              !isManuallyHidden(currentSession) else { return }

        let client = dataSources.notificationClient
        let request = Self.notificationRequest(for: session)
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

    private func removeNotification(identifier: String) {
        let client = dataSources.notificationClient
        client.removePending([identifier])
        client.removeDelivered([identifier])
    }
}
