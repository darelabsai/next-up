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
