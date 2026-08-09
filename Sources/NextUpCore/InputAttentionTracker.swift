import Foundation

public struct InputAttentionTracker: Sendable {
    public private(set) var activeLaneIDs: Set<String> = []
    private var lastAnnouncedAt: [String: Date] = [:]
    private var announcementCounts: [String: Int] = [:]
    private var acknowledgedLaneIDs: Set<String> = []

    public init() {}

    public mutating func observe(_ snapshots: [LaneSnapshot]) {
        let current = Set(snapshots.lazy.filter { $0.state == .inputRequired }.map(\.id))
        let resolved = activeLaneIDs.subtracting(current)
        for laneID in resolved {
            lastAnnouncedAt.removeValue(forKey: laneID)
            announcementCounts.removeValue(forKey: laneID)
            acknowledgedLaneIDs.remove(laneID)
        }
        activeLaneIDs = current
    }

    public func due(at date: Date) -> [String] {
        activeLaneIDs
            .filter { laneID in
                guard !acknowledgedLaneIDs.contains(laneID) else { return false }
                return ReminderSchedule.isDue(
                    announcementCount: announcementCounts[laneID] ?? 0,
                    lastAnnouncedAt: lastAnnouncedAt[laneID],
                    at: date
                )
            }
            .sorted()
    }

    public mutating func markAnnounced(laneIDs: Set<String>, at date: Date) {
        for laneID in laneIDs where activeLaneIDs.contains(laneID) {
            lastAnnouncedAt[laneID] = date
            announcementCounts[laneID] = ReminderSchedule.normalizedCount(
                (announcementCounts[laneID] ?? 0) + 1
            )
        }
    }

    public mutating func acknowledge(laneID: String) {
        guard activeLaneIDs.contains(laneID) else { return }
        acknowledgedLaneIDs.insert(laneID)
    }
}
