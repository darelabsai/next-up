import Foundation
import NextUpCore
import UserNotifications

enum NotificationResponseDecision: Equatable, Sendable {
    case navigate(CMUXNavigationTarget?, acknowledgingLaneID: String?)
    case acknowledge(String)
    case ignore
}

enum NotificationResponseRouter {
    static func route(
        actionIdentifier: String,
        userInfo: [String: String]
    ) -> NotificationResponseDecision {
        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            let laneID = userInfo["laneID"].flatMap { $0.isEmpty ? nil : $0 }
            return .navigate(
                CMUXNavigationTarget(userInfo: userInfo),
                acknowledgingLaneID: laneID
            )
        }
        if actionIdentifier == NextUpNotification.markSeenActionID,
           let laneID = userInfo["laneID"], !laneID.isEmpty {
            return .acknowledge(laneID)
        }
        return .ignore
    }
}
