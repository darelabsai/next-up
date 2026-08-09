import Foundation

public enum NextUpNotificationUserInfo {
    public static func make(
        laneID: String,
        kind: String,
        navigationTarget: CMUXNavigationTarget?
    ) -> [String: String] {
        var values = navigationTarget?.userInfo ?? [:]
        values["laneID"] = laneID
        values["kind"] = kind
        return values
    }
}
