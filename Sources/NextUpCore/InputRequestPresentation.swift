import Foundation

public struct InputRequestNotificationPresentation: Codable, Equatable, Sendable {
    public let laneID: String
    public let identifier: String
    public let userInfo: [String: String]
    public let title: String
    public let body: String

    public init(
        laneID: String,
        identifier: String,
        userInfo: [String: String],
        title: String,
        body: String
    ) {
        self.laneID = laneID
        self.identifier = identifier
        self.userInfo = userInfo
        self.title = title
        self.body = body
    }
}

public struct InputAttentionAnnouncementPlan: Codable, Equatable, Sendable {
    public let spoken: String?
    public let notifications: [InputRequestNotificationPresentation]
    public let shouldSpeakCompletions: Bool

    public init(
        spoken: String?,
        notifications: [InputRequestNotificationPresentation],
        shouldSpeakCompletions: Bool
    ) {
        self.spoken = spoken
        self.notifications = notifications
        self.shouldSpeakCompletions = shouldSpeakCompletions
    }
}

public enum InputAttentionAnnouncementPlanner {
    public static func plan(
        lanes: [LaneSnapshot],
        dueLaneIDs: Set<String>,
        voiceMode: VoiceAnnouncementMode,
        completionsAreDue: Bool
    ) -> InputAttentionAnnouncementPlan {
        let dueLanes = lanes.filter { dueLaneIDs.contains($0.id) }
        let items = dueLanes.map { lane in
            Item(
                laneID: lane.id,
                name: LaneMonitorState.displayName(from: lane.title),
                kind: lane.inputRequestKind ?? .response,
                navigationTarget: lane.navigationTarget
            )
        }
        let spoken: String?
        if voiceMode == .off || items.isEmpty {
            spoken = nil
        } else {
            spoken = "Heads up. " + items.map(spokenSentence).joined(separator: " ")
        }
        let notifications = items.map { item in
            InputRequestNotificationPresentation(
                laneID: item.laneID,
                identifier: "next-up-\(item.laneID)",
                userInfo: item.userInfo,
                title: "\(item.name) needs attention",
                body: notificationBody(for: item.kind)
            )
        }
        return InputAttentionAnnouncementPlan(
            spoken: spoken,
            notifications: notifications,
            shouldSpeakCompletions: dueLanes.isEmpty && completionsAreDue
        )
    }

    private static func spokenSentence(_ item: Item) -> String {
        switch item.kind {
        case .approval:
            return "\(item.name) needs your approval."
        case .clarification:
            return "\(item.name) has a question for you."
        case .response:
            return "\(item.name) is waiting for your response."
        }
    }

    private static func notificationBody(for kind: InputRequestKind) -> String {
        switch kind {
        case .approval:
            return "Approval required in Hermes."
        case .clarification:
            return "Question waiting in Hermes."
        case .response:
            return "Response required in Hermes."
        }
    }

    private struct Item {
        let laneID: String
        let name: String
        let kind: InputRequestKind
        let navigationTarget: CMUXNavigationTarget?

        var userInfo: [String: String] {
            NextUpNotificationUserInfo.make(
                laneID: laneID,
                kind: "input-required",
                navigationTarget: navigationTarget
            )
        }
    }
}
