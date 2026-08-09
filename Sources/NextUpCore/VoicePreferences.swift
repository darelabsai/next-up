import Foundation

public enum VoiceAnnouncementMode: String, Codable, CaseIterable, Sendable {
    case off
    case titleOnly
    case titleAndSummary

    public var displayName: String {
        switch self {
        case .off: return "Voice Off"
        case .titleOnly: return "Lane Title Only"
        case .titleAndSummary: return "Lane + Summary"
        }
    }
}

public struct VoicePreferences: Codable, Equatable, Sendable {
    public var mode: VoiceAnnouncementMode

    public init(mode: VoiceAnnouncementMode = .titleAndSummary) {
        self.mode = mode
    }
}

public enum VoiceAnnouncementFormatter {
    public static func completions(
        _ completions: [PendingCompletion],
        mode: VoiceAnnouncementMode,
        at date: Date
    ) -> String? {
        switch mode {
        case .off:
            return nil
        case .titleAndSummary:
            return CompletionAnnouncementFormatter.spoken(completions, at: date)
        case .titleOnly:
            let withoutSummaries = completions.map {
                PendingCompletion(
                    laneID: $0.laneID, title: $0.title,
                    displayName: $0.displayName, summary: nil,
                    workspaceID: $0.workspaceID,
                    workspaceTitle: $0.workspaceTitle,
                    completedAt: $0.completedAt,
                    lastAnnouncedAt: $0.lastAnnouncedAt
                )
            }
            return CompletionAnnouncementFormatter.spoken(withoutSummaries, at: date)
        }
    }

    public static func inputRequired(
        laneNames: [String],
        mode: VoiceAnnouncementMode
    ) -> String? {
        let lanes = laneNames.enumerated().map { index, name in
            LaneSnapshot(
                id: "legacy-input-\(index)", title: name,
                state: .inputRequired, inputRequestKind: .response
            )
        }
        return InputAttentionAnnouncementPlanner.plan(
            lanes: lanes,
            dueLaneIDs: Set(lanes.map(\.id)),
            voiceMode: mode,
            completionsAreDue: false
        ).spoken
    }
}
