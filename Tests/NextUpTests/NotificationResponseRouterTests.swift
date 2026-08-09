import Testing
import UserNotifications
@testable import NextUp
@testable import NextUpCore

@Test func defaultNotificationActionNavigatesAndAcknowledges() {
    let target = CMUXNavigationTarget(windowID: "W", workspaceID: "WS", surfaceID: "S")
    var userInfo = target.userInfo
    userInfo["laneID"] = "surface:1"

    let decision = NotificationResponseRouter.route(
        actionIdentifier: UNNotificationDefaultActionIdentifier,
        userInfo: userInfo
    )

    #expect(decision == .navigate(target, acknowledgingLaneID: "surface:1"))
}

@Test func malformedDefaultNotificationStillRequestsAppOnlyNavigation() {
    let decision = NotificationResponseRouter.route(
        actionIdentifier: UNNotificationDefaultActionIdentifier,
        userInfo: ["laneID": "surface:1", "cmuxSurfaceID": ""]
    )

    #expect(decision == .navigate(nil, acknowledgingLaneID: "surface:1"))
}

@Test func malformedDefaultNotificationWithoutLaneStillRequestsAppOnlyNavigation() {
    let decision = NotificationResponseRouter.route(
        actionIdentifier: UNNotificationDefaultActionIdentifier,
        userInfo: [:]
    )

    #expect(decision == .navigate(nil, acknowledgingLaneID: nil))
}

@Test func markSeenAcknowledgesWithoutNavigation() {
    let decision = NotificationResponseRouter.route(
        actionIdentifier: NextUpNotification.markSeenActionID,
        userInfo: ["laneID": "surface:1", "cmuxSurfaceID": "S"]
    )

    #expect(decision == .acknowledge("surface:1"))
}

@Test func malformedMarkSeenAndUnknownActionsAreIgnored() {
    #expect(NotificationResponseRouter.route(
        actionIdentifier: NextUpNotification.markSeenActionID,
        userInfo: [:]
    ) == .ignore)
    #expect(NotificationResponseRouter.route(
        actionIdentifier: "UNKNOWN",
        userInfo: ["laneID": "surface:1"]
    ) == .ignore)
}

@Test func sharedNotificationUserInfoCarriesOnlyKindLaneAndOpaqueRoute() {
    let target = CMUXNavigationTarget(
        windowID: "W", windowRef: "window:1",
        workspaceID: "WS", workspaceRef: "workspace:1",
        paneID: "P", paneRef: "pane:1",
        surfaceID: "S", surfaceRef: "surface:1"
    )

    let userInfo = NextUpNotificationUserInfo.make(
        laneID: "surface:1", kind: "completion", navigationTarget: target
    )

    #expect(userInfo["laneID"] == "surface:1")
    #expect(userInfo["kind"] == "completion")
    #expect(CMUXNavigationTarget(userInfo: userInfo) == target)
    #expect(!userInfo.values.contains("SENTINEL PRIVATE TITLE"))
}
