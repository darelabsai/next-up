import NextUpCore

enum WatcherFocusAcknowledgementApplicator {
    static func apply(
        laneIDs: Set<String>,
        state: inout LaneMonitorState,
        attentionTracker: inout InputAttentionTracker
    ) -> Set<String> {
        let completionLaneIDs = Set(state.pending.map(\.laneID))
        let inputLaneIDs = attentionTracker.activeLaneIDs
        let acknowledged = laneIDs.intersection(completionLaneIDs.union(inputLaneIDs))

        for laneID in acknowledged {
            state.acknowledge(laneID: laneID)
            attentionTracker.acknowledge(laneID: laneID)
        }
        return acknowledged
    }
}
