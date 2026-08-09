import Foundation
import Testing
@testable import NextUpCore

@Test func laneOrderingPrioritizesInputCompletionWorkAndRecency() {
    let lanes = [
        LaneSnapshot(id: "idle", title: "Idle", state: .ready),
        LaneSnapshot(id: "busy-old", title: "Busy Old", state: .busy),
        LaneSnapshot(id: "completion", title: "Completion", state: .ready),
        LaneSnapshot(id: "attention", title: "Attention", state: .inputRequired),
        LaneSnapshot(id: "busy-new", title: "Busy New", state: .busy),
    ]
    let sorted = LaneOrdering.sorted(
        lanes,
        pendingLaneIDs: ["completion"],
        activityDates: [
            "busy-old": Date(timeIntervalSince1970: 100),
            "busy-new": Date(timeIntervalSince1970: 200),
        ]
    )
    #expect(sorted.map(\.id) == ["attention", "completion", "busy-new", "busy-old", "idle"])
}

@Test func activityHistorySurvivesRestartAndEphemeralRefChanges() {
    let restored = Date(timeIntervalSince1970: 100)
    let now = Date(timeIntervalSince1970: 500)
    let oldRef = LaneSnapshot(
        id: "surface:1", persistentID: "stable-surface",
        title: "Lane", state: .ready
    )
    let newRef = LaneSnapshot(
        id: "surface:99", persistentID: "stable-surface",
        title: "Lane", state: .ready
    )

    let afterRestart = LaneActivityHistory.updatedDates(
        existing: ["stable-surface": restored],
        previous: [], current: [newRef], now: now
    )
    let afterRefChange = LaneActivityHistory.updatedDates(
        existing: afterRestart,
        previous: [oldRef], current: [newRef], now: now
    )

    #expect(afterRestart["stable-surface"] == restored)
    #expect(afterRefChange["stable-surface"] == restored)
}
