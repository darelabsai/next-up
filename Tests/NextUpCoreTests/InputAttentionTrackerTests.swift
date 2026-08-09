import Foundation
import Testing
@testable import NextUpCore

@Test func inputAttentionAlertsImmediatelyAndRepeatsWhileUnresolved() {
    var tracker = InputAttentionTracker()
    let lane = LaneSnapshot(id: "one", title: "Approval", state: .inputRequired)

    tracker.observe([lane])
    #expect(tracker.due(at: Date(timeIntervalSince1970: 100)) == ["one"])
    tracker.markAnnounced(laneIDs: ["one"], at: Date(timeIntervalSince1970: 100))
    #expect(tracker.due(at: Date(timeIntervalSince1970: 399)).isEmpty)
    #expect(tracker.due(at: Date(timeIntervalSince1970: 400)) == ["one"])
    tracker.markAnnounced(laneIDs: ["one"], at: Date(timeIntervalSince1970: 400))
    #expect(tracker.due(at: Date(timeIntervalSince1970: 999)).isEmpty)
    #expect(tracker.due(at: Date(timeIntervalSince1970: 1_000)) == ["one"])
}

@Test func inputAttentionClearsOnResumeAndCanAlertAgainLater() {
    var tracker = InputAttentionTracker()
    let attention = LaneSnapshot(id: "one", title: "Approval", state: .inputRequired)
    let busy = LaneSnapshot(id: "one", title: "Approval", state: .busy)

    tracker.observe([attention])
    tracker.markAnnounced(laneIDs: ["one"], at: Date(timeIntervalSince1970: 100))
    tracker.observe([busy])
    #expect(tracker.activeLaneIDs.isEmpty)
    tracker.observe([attention])
    #expect(tracker.due(at: Date(timeIntervalSince1970: 110)) == ["one"])
}

@Test func acknowledgingInputSuppressesRepeatsUntilLaneResumes() {
    var tracker = InputAttentionTracker()
    let attention = LaneSnapshot(id: "one", title: "Approval", state: .inputRequired)

    tracker.observe([attention])
    tracker.acknowledge(laneID: "one")

    #expect(tracker.due(at: Date(timeIntervalSince1970: 500)).isEmpty)
}

@Test func requestKindChangePreservesExistingReminderCadence() {
    var tracker = InputAttentionTracker()
    let approval = LaneSnapshot(
        id: "one", title: "Approval", state: .inputRequired,
        inputRequestKind: .approval
    )
    let clarification = LaneSnapshot(
        id: "one", title: "Question", state: .inputRequired,
        inputRequestKind: .clarification
    )

    tracker.observe([approval])
    tracker.markAnnounced(laneIDs: ["one"], at: Date(timeIntervalSince1970: 100))
    tracker.observe([clarification])

    #expect(tracker.due(at: Date(timeIntervalSince1970: 399)).isEmpty)
    #expect(tracker.due(at: Date(timeIntervalSince1970: 400)) == ["one"])
}

@Test func requestKindChangePreservesAcknowledgement() {
    var tracker = InputAttentionTracker()
    let approval = LaneSnapshot(
        id: "one", title: "Approval", state: .inputRequired,
        inputRequestKind: .approval
    )
    let clarification = LaneSnapshot(
        id: "one", title: "Question", state: .inputRequired,
        inputRequestKind: .clarification
    )

    tracker.observe([approval])
    tracker.acknowledge(laneID: "one")
    tracker.observe([clarification])

    #expect(tracker.due(at: Date(timeIntervalSince1970: 500)).isEmpty)
}

@Test func inputAttentionRoundTripsCapturedRouteAndAcknowledgement() throws {
    let route = completeRoute(surfaceID: "surface-a")
    var tracker = InputAttentionTracker()
    tracker.observe([inputLane(route: route)])
    tracker.markAnnounced(laneIDs: ["one"], at: Date(timeIntervalSince1970: 100))
    tracker.acknowledge(laneID: "one")

    let data = try JSONEncoder().encode(tracker)
    let restored = try JSONDecoder().decode(InputAttentionTracker.self, from: data)

    #expect(restored == tracker)
    #expect(restored.navigationTarget(for: "one") == route)
    #expect(restored.isAcknowledged(laneID: "one"))
    #expect(restored.due(at: Date(timeIntervalSince1970: 1_000)).isEmpty)
}

@Test func inputAttentionLearnsRouteWithoutReplacingSameRequestIdentity() {
    let original = completeRoute(surfaceID: "surface-a", surfaceRef: "surface-ref")
    let changedRefs = CMUXNavigationTarget(
        windowID: "window", windowRef: "new-window-ref",
        workspaceID: "workspace", workspaceRef: "new-workspace-ref",
        paneID: "pane", paneRef: "new-pane-ref",
        surfaceID: "surface-a", surfaceRef: "new-surface-ref"
    )
    var tracker = InputAttentionTracker()

    tracker.observe([inputLane(route: original)])
    tracker.observe([inputLane(route: changedRefs)])

    #expect(tracker.navigationTarget(for: "one") == original)
}

@Test func conflictingStrongIdentityRetainsOriginalRouteUntilActualResolution() {
    let original = completeRoute(surfaceID: "surface-a", surfaceRef: "surface-ref")
    let replacement = completeRoute(surfaceID: "surface-b", surfaceRef: "surface-ref")
    var tracker = InputAttentionTracker()

    tracker.observe([inputLane(route: original)])
    tracker.acknowledge(laneID: "one")
    tracker.observe([inputLane(route: replacement)])

    #expect(tracker.navigationTarget(for: "one") == original)
    #expect(tracker.isAcknowledged(laneID: "one"))
    #expect(tracker.due(at: Date(timeIntervalSince1970: 100)).isEmpty)

    tracker.observe([inputLane(route: replacement)])
    #expect(tracker.navigationTarget(for: "one") == original)
}

@Test func conflictingRouteCannotBeLaunderedAcrossPersistenceRestart() throws {
    let original = completeRoute(surfaceID: "surface-a")
    let replacement = completeRoute(surfaceID: "surface-b")
    var tracker = InputAttentionTracker()
    tracker.observe([inputLane(route: original)])
    tracker.observe([inputLane(route: replacement)])

    let restored = try JSONDecoder().decode(
        InputAttentionTracker.self,
        from: JSONEncoder().encode(tracker)
    )
    var continued = restored
    continued.observe([inputLane(route: replacement)])

    #expect(continued.navigationTarget(for: "one") == original)
}

@Test func resolvedInputClearsCapturedRouteBeforeNewRequest() {
    let original = completeRoute(surfaceID: "surface-a")
    let replacement = completeRoute(surfaceID: "surface-b")
    var tracker = InputAttentionTracker()

    tracker.observe([inputLane(route: original)])
    tracker.observe([LaneSnapshot(id: "one", title: "Working", state: .busy)])
    tracker.observe([inputLane(route: replacement)])

    #expect(tracker.navigationTarget(for: "one") == replacement)
    #expect(!tracker.isAcknowledged(laneID: "one"))
}

private func inputLane(route: CMUXNavigationTarget) -> LaneSnapshot {
    LaneSnapshot(
        id: "one",
        title: "Approval",
        state: .inputRequired,
        navigationTarget: route
    )
}

private func completeRoute(
    surfaceID: String,
    surfaceRef: String = "surface-ref"
) -> CMUXNavigationTarget {
    CMUXNavigationTarget(
        windowID: "window", windowRef: "window-ref",
        workspaceID: "workspace", workspaceRef: "workspace-ref",
        paneID: "pane", paneRef: "pane-ref",
        surfaceID: surfaceID, surfaceRef: surfaceRef
    )
}
