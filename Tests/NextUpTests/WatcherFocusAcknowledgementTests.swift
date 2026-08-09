import Foundation
import Testing
import NextUpCore
@testable import NextUp

@Test func focusAcknowledgementAppliesCompletionAndInputInOneBatch() {
    let now = Date(timeIntervalSince1970: 100)
    var state = LaneMonitorState()
    state.establishBaseline([
        LaneSnapshot(id: "completion", title: "Completion", state: .busy),
        LaneSnapshot(id: "other", title: "Other", state: .busy),
    ])
    state.observe([
        LaneSnapshot(id: "completion", title: "Completion", state: .ready),
        LaneSnapshot(id: "other", title: "Other", state: .ready),
    ], now: now)
    var attention = InputAttentionTracker()
    attention.observe([
        LaneSnapshot(id: "input", title: "Input", state: .inputRequired),
        LaneSnapshot(id: "other-input", title: "Other input", state: .inputRequired),
    ])

    let removed = WatcherFocusAcknowledgementApplicator.apply(
        laneIDs: ["completion", "input", "missing"],
        state: &state,
        attentionTracker: &attention
    )

    #expect(removed == ["completion", "input"])
    #expect(!state.pending.contains { $0.laneID == "completion" })
    #expect(state.pending.contains { $0.laneID == "other" })
    #expect(attention.isAcknowledged(laneID: "input"))
    #expect(!attention.isAcknowledged(laneID: "other-input"))
    #expect(state.previous["completion"] == .ready)
    #expect(state.completionsDueForAnnouncement(at: now).map(\.laneID) == ["other"])
}

@Test func focusAcknowledgementDeduplicatesLanePresentInBothAlertKinds() {
    let now = Date(timeIntervalSince1970: 100)
    var state = LaneMonitorState()
    state.establishBaseline([LaneSnapshot(id: "shared", title: "Shared", state: .busy)])
    state.observe([LaneSnapshot(id: "shared", title: "Shared", state: .ready)], now: now)
    var attention = InputAttentionTracker()
    attention.observe([LaneSnapshot(id: "shared", title: "Shared", state: .inputRequired)])

    let removed = WatcherFocusAcknowledgementApplicator.apply(
        laneIDs: ["shared"],
        state: &state,
        attentionTracker: &attention
    )

    #expect(removed == ["shared"])
    #expect(state.pending.isEmpty)
    #expect(attention.isAcknowledged(laneID: "shared"))
}

@Test func existingFocusedCompletionAndInputEligibilityArePrivacySafeAndAcknowledgedInBatch() throws {
    let route = acknowledgementRoute()
    let now = Date(timeIntervalSince1970: 100)
    var state = LaneMonitorState()
    state.establishBaseline([LaneSnapshot(id: "shared", title: "Work", state: .busy)])
    state.observe([LaneSnapshot(
        id: "shared", title: "Work", state: .ready, navigationTarget: route
    )], now: now)
    var attention = InputAttentionTracker()
    attention.observe([LaneSnapshot(
        id: "shared", title: "Approval", state: .inputRequired, navigationTarget: route
    )])

    let eligible = WatcherFocusReconciliation.eligibleAlerts(state: state, attentionTracker: attention)
    let plan = WatcherFocusReconciliation.plan(
        eligibleAlerts: eligible,
        observation: acknowledgementFocus(route: route, at: now),
        reconciledAt: now
    )
    let acknowledged = WatcherFocusAcknowledgementApplicator.apply(
        laneIDs: Set(plan.suppressions.map(\.laneID)),
        state: &state,
        attentionTracker: &attention
    )

    #expect(Set(eligible.map(\.kind)) == [.completion, .inputRequired])
    #expect(plan.suppressions.count == 2)
    #expect(acknowledged == ["shared"])
    #expect(state.pending.isEmpty)
    #expect(attention.isAcknowledged(laneID: "shared"))
}

@Test func newlyCreatedFocusedCandidateIsPlannedBeforeItCanBecomeDue() {
    let route = acknowledgementRoute()
    let now = Date(timeIntervalSince1970: 100)
    var state = LaneMonitorState()
    state.establishBaseline([LaneSnapshot(id: "lane", title: "Work", state: .busy)])
    var attention = InputAttentionTracker()
    let before = WatcherFocusReconciliation.eligibleAlerts(state: state, attentionTracker: attention)
    state.observe([LaneSnapshot(
        id: "lane", title: "Work", state: .ready, navigationTarget: route
    )], now: now)
    let current = WatcherFocusReconciliation.eligibleAlerts(state: state, attentionTracker: attention)
    var focusReads = 0

    let plan = WatcherFocusReconciliation.planNewSuppressions(
        previousAlerts: before,
        currentAlerts: current,
        reconciledAt: now,
        acquireFreshFocus: {
            focusReads += 1
            return acknowledgementFocus(route: route, at: now)
        }
    )
    _ = WatcherFocusAcknowledgementApplicator.apply(
        laneIDs: Set(plan.suppressions.map(\.laneID)),
        state: &state,
        attentionTracker: &attention
    )

    #expect(focusReads == 1)
    #expect(plan.suppressions.map(\.laneID) == ["lane"])
    #expect(state.completionsDueForAnnouncement(at: now).isEmpty)
}

@Test func noNewCandidatePerformsNoPostEnrichmentFocusRead() {
    let route = acknowledgementRoute()
    let alert = FocusAlertIdentity(kind: .completion, laneID: "existing", navigationTarget: route)
    var focusReads = 0

    let plan = WatcherFocusReconciliation.planNewSuppressions(
        previousAlerts: [alert],
        currentAlerts: [alert],
        reconciledAt: Date(timeIntervalSince1970: 100),
        acquireFreshFocus: {
            focusReads += 1
            return acknowledgementFocus(route: route, at: Date(timeIntervalSince1970: 100))
        }
    )

    #expect(focusReads == 0)
    #expect(plan.suppressions.isEmpty)
    #expect(plan.observationTimestamp == nil)
}

@Test func focusFreshnessAndReceiptTimestampUseAcquisitionStart() {
    let route = acknowledgementRoute()
    let startedAt = Date(timeIntervalSince1970: 100)
    let finishedAt = Date(timeIntervalSince1970: 101.9)
    let observation = CMUXFreshFocusAcquisition(
        snapshot: acknowledgementFocus(route: route, at: startedAt).snapshot,
        isCMUXFrontmost: true,
        startedAt: startedAt,
        finishedAt: finishedAt
    )
    let alert = FocusAlertIdentity(kind: .completion, laneID: "lane", navigationTarget: route)

    let fresh = WatcherFocusReconciliation.plan(
        eligibleAlerts: [alert], observation: observation,
        reconciledAt: Date(timeIntervalSince1970: 102)
    )
    let stale = WatcherFocusReconciliation.plan(
        eligibleAlerts: [alert], observation: observation,
        reconciledAt: Date(timeIntervalSince1970: 102.001)
    )

    #expect(fresh.suppressions == [alert])
    #expect(fresh.observationTimestamp == startedAt)
    #expect(stale == .empty)
}

@Test func queuedEligibilityCannotCrossAReusedLaneIDWithDifferentPersistentRoute() {
    let requested = FocusAlertIdentity(
        kind: .completion,
        laneID: "reused-lane",
        navigationTarget: acknowledgementRoute()
    )
    let replacement = FocusAlertIdentity(
        kind: .completion,
        laneID: "reused-lane",
        navigationTarget: CMUXNavigationTarget(
            windowID: "replacement-window", windowRef: requested.navigationTarget.windowRef,
            workspaceID: "replacement-workspace", workspaceRef: requested.navigationTarget.workspaceRef,
            paneID: "replacement-pane", paneRef: requested.navigationTarget.paneRef,
            surfaceID: "replacement-surface", surfaceRef: requested.navigationTarget.surfaceRef
        )
    )

    #expect(!WatcherFocusReconciliation.sameIdentity(requested, replacement))
    #expect(WatcherFocusReconciliation.sameIdentity(requested, requested))
}

private func acknowledgementRoute() -> CMUXNavigationTarget {
    CMUXNavigationTarget(
        windowID: "window", windowRef: "window-ref",
        workspaceID: "workspace", workspaceRef: "workspace-ref",
        paneID: "pane", paneRef: "pane-ref",
        surfaceID: "surface", surfaceRef: "surface-ref"
    )
}

private func acknowledgementFocus(
    route: CMUXNavigationTarget,
    at date: Date
) -> CMUXFreshFocusAcquisition {
    CMUXFreshFocusAcquisition(
        snapshot: CMUXWorkspaceInventorySnapshot(
            records: [WorkspaceInventoryRecord(
                info: WorkspaceInfo(id: "workspace-ref", persistentID: "workspace", title: "Work"),
                lanes: [LaneSnapshot(
                    id: "focused", title: "Focused", state: .unknown, navigationTarget: route
                )]
            )],
            activeFocus: CMUXActiveFocus(
                windowID: route.windowID, windowRef: route.windowRef,
                workspaceID: route.workspaceID, workspaceRef: route.workspaceRef,
                paneID: route.paneID, paneRef: route.paneRef,
                surfaceID: route.surfaceID, surfaceRef: route.surfaceRef
            )
        ),
        isCMUXFrontmost: true,
        startedAt: date,
        finishedAt: date
    )
}
