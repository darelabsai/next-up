import Foundation

public struct LaneObservationSession: Sendable {
    private var baselinedLaneIDs: Set<String> = []

    public init() {}

    public mutating func retain(liveLaneIDs: Set<String>) {
        baselinedLaneIDs.formIntersection(liveLaneIDs)
    }

    public func hasBaseline(for laneID: String) -> Bool {
        baselinedLaneIDs.contains(laneID)
    }

    public mutating func observe(
        _ snapshots: [LaneSnapshot],
        state: inout LaneMonitorState,
        now: Date
    ) {
        let baseline = snapshots.filter { !baselinedLaneIDs.contains($0.id) }
        let observed = snapshots.filter { baselinedLaneIDs.contains($0.id) }
        if !baseline.isEmpty {
            state.establishBaseline(baseline)
            baselinedLaneIDs.formUnion(baseline.map(\.id))
        }
        if !observed.isEmpty {
            state.observe(observed, now: now)
        }
    }
}
