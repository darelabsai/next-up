import Foundation

public enum LaneState: String, Codable, Sendable {
    case busy
    case inputRequired
    case ready
    case unknown
}

public struct LaneSnapshot: Equatable, Sendable {
    public let id: String
    public let persistentID: String?
    public let title: String
    public let state: LaneState
    public let inputRequestKind: InputRequestKind?
    public let summary: String?
    public let matchingSnippet: String?
    public let workspaceID: String
    public let workspacePersistentID: String?
    public let workspaceTitle: String
    public let machine: String
    public let hermesProfile: String
    public let navigationTarget: CMUXNavigationTarget?

    public init(
        id: String,
        persistentID: String? = nil,
        title: String,
        state: LaneState,
        inputRequestKind: InputRequestKind? = nil,
        summary: String? = nil,
        matchingSnippet: String? = nil,
        workspaceID: String = "",
        workspacePersistentID: String? = nil,
        workspaceTitle: String = "",
        machine: String = "mac-air",
        hermesProfile: String = "default",
        navigationTarget: CMUXNavigationTarget? = nil
    ) {
        self.id = id
        self.persistentID = persistentID
        self.title = title
        self.state = state
        self.inputRequestKind = state == .inputRequired ? inputRequestKind : nil
        self.summary = state == .inputRequired ? nil : summary
        self.matchingSnippet = state == .inputRequired ? nil : matchingSnippet
        self.workspaceID = workspaceID
        self.workspacePersistentID = workspacePersistentID
        self.workspaceTitle = workspaceTitle
        self.machine = machine
        self.hermesProfile = hermesProfile
        self.navigationTarget = navigationTarget
    }

    public func withSummary(_ newSummary: String?) -> LaneSnapshot {
        LaneSnapshot(
            id: id, persistentID: persistentID, title: title, state: state,
            inputRequestKind: inputRequestKind,
            summary: state == .inputRequired ? nil : newSummary,
            matchingSnippet: state == .inputRequired ? nil : matchingSnippet,
            workspaceID: workspaceID,
            workspacePersistentID: workspacePersistentID,
            workspaceTitle: workspaceTitle, machine: machine,
            hermesProfile: hermesProfile,
            navigationTarget: navigationTarget
        )
    }
}

public struct PendingCompletion: Identifiable, Equatable, Codable, Sendable {
    public let laneID: String
    public var title: String
    public var displayName: String
    public var summary: String?
    public var workspaceID: String?
    public var workspaceTitle: String?
    public var navigationTarget: CMUXNavigationTarget?
    public let completedAt: Date
    public var lastAnnouncedAt: Date?
    public var announcementCount: Int

    public init(
        laneID: String,
        title: String,
        displayName: String,
        summary: String? = nil,
        workspaceID: String? = nil,
        workspaceTitle: String? = nil,
        completedAt: Date,
        lastAnnouncedAt: Date? = nil,
        announcementCount: Int = 0,
        navigationTarget: CMUXNavigationTarget? = nil
    ) {
        self.laneID = laneID
        self.title = title
        self.displayName = displayName
        self.summary = summary.map(CompletionSummaryExtractor.bounded)
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.completedAt = completedAt
        self.lastAnnouncedAt = lastAnnouncedAt
        self.announcementCount = ReminderSchedule.normalizedCount(announcementCount)
        self.navigationTarget = navigationTarget
    }

    private enum CodingKeys: String, CodingKey {
        case laneID, title, displayName, summary, workspaceID, workspaceTitle
        case completedAt, lastAnnouncedAt, announcementCount, navigationTarget
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        laneID = try container.decode(String.self, forKey: .laneID)
        title = try container.decode(String.self, forKey: .title)
        displayName = try container.decode(String.self, forKey: .displayName)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        workspaceTitle = try container.decodeIfPresent(String.self, forKey: .workspaceTitle)
        completedAt = try container.decode(Date.self, forKey: .completedAt)
        lastAnnouncedAt = try container.decodeIfPresent(Date.self, forKey: .lastAnnouncedAt)
        navigationTarget = try container.decodeIfPresent(
            CMUXNavigationTarget.self,
            forKey: .navigationTarget
        )
        if lastAnnouncedAt == nil {
            announcementCount = 0
        } else if let decoded = try? container.decode(Int.self, forKey: .announcementCount), decoded > 0 {
            announcementCount = ReminderSchedule.normalizedCount(decoded)
        } else {
            announcementCount = 1
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(laneID, forKey: .laneID)
        try container.encode(title, forKey: .title)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(workspaceTitle, forKey: .workspaceTitle)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(lastAnnouncedAt, forKey: .lastAnnouncedAt)
        try container.encode(announcementCount, forKey: .announcementCount)
        try container.encodeIfPresent(navigationTarget, forKey: .navigationTarget)
    }

    public var id: String { laneID }
}

public struct LaneMonitorState: Codable, Equatable, Sendable {

    public private(set) var previous: [String: LaneState] = [:]
    public private(set) var pending: [PendingCompletion] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case previous
        case pending
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        previous = try container.decodeIfPresent([String: LaneState].self, forKey: .previous) ?? [:]
        pending = try container.decodeIfPresent([PendingCompletion].self, forKey: .pending) ?? []
        for index in pending.indices {
            if let summary = pending[index].summary {
                pending[index].summary = CompletionSummaryExtractor.bounded(summary)
            }
        }
    }

    public mutating func establishBaseline(_ snapshots: [LaneSnapshot]) {
        for snapshot in snapshots {
            previous[snapshot.id] = snapshot.state
            if snapshot.state == .busy || snapshot.state == .inputRequired {
                pending.removeAll { $0.laneID == snapshot.id }
            }
        }
    }

    public mutating func observe(_ snapshots: [LaneSnapshot], now: Date) {
        for snapshot in snapshots {
            if snapshot.state == .busy || snapshot.state == .inputRequired {
                pending.removeAll { $0.laneID == snapshot.id }
            }
            if previous[snapshot.id] == .busy && snapshot.state == .ready,
               !pending.contains(where: { $0.laneID == snapshot.id }) {
                pending.append(PendingCompletion(
                    laneID: snapshot.id,
                    title: snapshot.title,
                    displayName: Self.displayName(from: snapshot.title),
                    summary: snapshot.summary,
                    workspaceID: snapshot.workspaceID.isEmpty ? nil : snapshot.workspaceID,
                    workspaceTitle: snapshot.workspaceTitle.isEmpty ? nil : snapshot.workspaceTitle,
                    completedAt: now,
                    lastAnnouncedAt: nil,
                    navigationTarget: snapshot.navigationTarget
                ))
            }
            previous[snapshot.id] = snapshot.state
        }
        pending.sort { $0.completedAt < $1.completedAt }
    }

    public mutating func forget(laneIDs: Set<String>) {
        for laneID in laneIDs {
            previous.removeValue(forKey: laneID)
        }
        pending.removeAll { laneIDs.contains($0.laneID) }
    }

    public mutating func acknowledge(laneID: String) {
        pending.removeAll { $0.laneID == laneID }
    }

    public func completionsDueForAnnouncement(at date: Date) -> [PendingCompletion] {
        pending.filter {
            ReminderSchedule.isDue(
                announcementCount: $0.announcementCount,
                lastAnnouncedAt: $0.lastAnnouncedAt,
                at: date
            )
        }
    }

    public mutating func markAnnounced(laneIDs: Set<String>, at date: Date) {
        for index in pending.indices where laneIDs.contains(pending[index].laneID) {
            pending[index].lastAnnouncedAt = date
            pending[index].announcementCount = ReminderSchedule.normalizedCount(
                pending[index].announcementCount + 1
            )
        }
    }

    public static func displayName(from title: String) -> String {
        var value = removingANSIEscapeSequences(from: title)
        value = String(value.unicodeScalars.filter {
            $0.properties.generalCategory != .control &&
                $0.properties.generalCategory != .format
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = value.range(of: " · ") {
            value = String(value[..<separator.lowerBound])
        }
        let ornaments: Set<Character> = ["⚠", "⚠️", "✓", "⏳"]
        while let first = value.first, ornaments.contains(first) {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespaces)
        }
        return value.isEmpty ? "Agent lane" : value
    }

    private static func removingANSIEscapeSequences(from text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = ""
        var index = 0
        while index < scalars.count {
            let value = scalars[index].value
            if value == 0x1B {
                guard index + 1 < scalars.count else { break }
                let next = scalars[index + 1].value
                switch next {
                case 0x5B:
                    index = endOfCSI(in: scalars, from: index + 2)
                case 0x5D:
                    index = endOfControlString(in: scalars, from: index + 2, allowsBell: true)
                case 0x50, 0x58, 0x5E, 0x5F:
                    index = endOfControlString(in: scalars, from: index + 2, allowsBell: false)
                default:
                    index += 1
                    while index < scalars.count,
                          (0x20...0x2F).contains(scalars[index].value) {
                        index += 1
                    }
                    if index < scalars.count { index += 1 }
                }
                continue
            }
            switch value {
            case 0x9B:
                index = endOfCSI(in: scalars, from: index + 1)
                continue
            case 0x9D:
                index = endOfControlString(in: scalars, from: index + 1, allowsBell: true)
                continue
            case 0x90, 0x98, 0x9E, 0x9F:
                index = endOfControlString(in: scalars, from: index + 1, allowsBell: false)
                continue
            default:
                result.unicodeScalars.append(scalars[index])
                index += 1
            }
        }
        return result
    }

    private static func endOfCSI(
        in scalars: [Unicode.Scalar],
        from start: Int
    ) -> Int {
        var index = start
        while index < scalars.count {
            let value = scalars[index].value
            index += 1
            if (0x40...0x7E).contains(value) { return index }
        }
        return index
    }

    private static func endOfControlString(
        in scalars: [Unicode.Scalar],
        from start: Int,
        allowsBell: Bool
    ) -> Int {
        var index = start
        while index < scalars.count {
            let value = scalars[index].value
            if allowsBell && value == 0x07 { return index + 1 }
            if value == 0x9C { return index + 1 }
            if value == 0x1B, index + 1 < scalars.count,
               scalars[index + 1].value == 0x5C {
                return index + 2
            }
            index += 1
        }
        return index
    }
}
