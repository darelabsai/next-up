import Foundation

public enum LaneOrdering {
    public static func sorted(
        _ lanes: [LaneSnapshot],
        pendingLaneIDs: Set<String>,
        activityDates: [String: Date]
    ) -> [LaneSnapshot] {
        lanes.sorted { left, right in
            let leftRank = rank(left, pendingLaneIDs: pendingLaneIDs)
            let rightRank = rank(right, pendingLaneIDs: pendingLaneIDs)
            if leftRank != rightRank { return leftRank < rightRank }
            let leftDate = activityDates[left.id] ?? .distantPast
            let rightDate = activityDates[right.id] ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    private static func rank(_ lane: LaneSnapshot, pendingLaneIDs: Set<String>) -> Int {
        if lane.state == .inputRequired { return 0 }
        if pendingLaneIDs.contains(lane.id) { return 1 }
        switch lane.state {
        case .busy: return 2
        case .ready: return 3
        case .unknown: return 4
        case .inputRequired: return 0
        }
    }
}

public enum LaneActivityHistory {
    public static func updatedDates(
        existing: [String: Date],
        previous: [LaneSnapshot],
        current: [LaneSnapshot],
        now: Date
    ) -> [String: Date] {
        let previousByKey = Dictionary(
            uniqueKeysWithValues: previous.map { (key(for: $0), $0) }
        )
        var updated = existing
        for lane in current {
            let laneKey = key(for: lane)
            if let prior = previousByKey[laneKey] {
                if prior.state != lane.state {
                    updated[laneKey] = now
                }
            } else if updated[laneKey] == nil {
                updated[laneKey] = now
            }
        }
        let liveKeys = Set(current.map(key(for:)))
        return updated.filter { liveKeys.contains($0.key) }
    }

    public static func key(for lane: LaneSnapshot) -> String {
        lane.persistentID ?? lane.id
    }
}
