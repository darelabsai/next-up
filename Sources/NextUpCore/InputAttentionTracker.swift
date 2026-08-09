import Foundation

public struct InputAttentionTracker: Codable, Equatable, Sendable {
    private struct Record: Codable, Equatable, Sendable {
        var navigationTarget: CMUXNavigationTarget?
        var lastAnnouncedAt: Date?
        var announcementCount: Int = 0
        var acknowledged = false
    }

    private var records: [String: Record] = [:]

    public var activeLaneIDs: Set<String> { Set(records.keys) }

    public init() {}

    public mutating func observe(_ snapshots: [LaneSnapshot]) {
        let current = snapshots.filter { $0.state == .inputRequired }
        let currentIDs = Set(current.map(\.id))
        records = records.filter { currentIDs.contains($0.key) }

        for snapshot in current {
            guard var record = records[snapshot.id] else {
                records[snapshot.id] = Record(
                    navigationTarget: Self.completeTarget(snapshot.navigationTarget)
                )
                continue
            }
            let observedTarget = Self.completeTarget(snapshot.navigationTarget)
            if let existingTarget = record.navigationTarget,
               let observedTarget,
               !Self.samePersistentRoute(existingTarget, observedTarget) {
                // A continuously active request has not resolved. Keep the first
                // complete persistent route authoritative instead of laundering a
                // conflict through an empty record that can learn a replacement.
            } else if record.navigationTarget == nil {
                record.navigationTarget = observedTarget
            }
            records[snapshot.id] = record
        }
    }

    public func due(at date: Date) -> [String] {
        activeLaneIDs
            .filter { laneID in
                guard let record = records[laneID], !record.acknowledged else { return false }
                return ReminderSchedule.isDue(
                    announcementCount: record.announcementCount,
                    lastAnnouncedAt: record.lastAnnouncedAt,
                    at: date
                )
            }
            .sorted()
    }

    public mutating func markAnnounced(laneIDs: Set<String>, at date: Date) {
        for laneID in laneIDs {
            guard var record = records[laneID] else { continue }
            record.lastAnnouncedAt = date
            record.announcementCount = ReminderSchedule.normalizedCount(record.announcementCount + 1)
            records[laneID] = record
        }
    }

    public mutating func acknowledge(laneID: String) {
        guard var record = records[laneID] else { return }
        record.acknowledged = true
        records[laneID] = record
    }

    public func navigationTarget(for laneID: String) -> CMUXNavigationTarget? {
        records[laneID]?.navigationTarget
    }

    public func isAcknowledged(laneID: String) -> Bool {
        records[laneID]?.acknowledged ?? false
    }

    private static func completeTarget(_ target: CMUXNavigationTarget?) -> CMUXNavigationTarget? {
        guard let target,
              target.windowID?.isEmpty == false,
              target.workspaceID?.isEmpty == false,
              target.paneID?.isEmpty == false,
              target.surfaceID?.isEmpty == false else { return nil }
        return target
    }

    private static func samePersistentRoute(
        _ lhs: CMUXNavigationTarget,
        _ rhs: CMUXNavigationTarget
    ) -> Bool {
        lhs.windowID == rhs.windowID &&
            lhs.workspaceID == rhs.workspaceID &&
            lhs.paneID == rhs.paneID &&
            lhs.surfaceID == rhs.surfaceID
    }
}
