import Foundation
import Testing
import NextUpCore
@testable import NextUp

private let probeRoute = CMUXNavigationTarget(
    windowID: "window-id", windowRef: nil,
    workspaceID: "workspace-id", workspaceRef: nil,
    paneID: "pane-id", paneRef: nil,
    surfaceID: "surface-id", surfaceRef: nil
)

private func probeObservation(at date: Date) -> CMUXFreshFocusAcquisition {
    let focus = CMUXActiveFocus(
        windowID: "window-id", windowRef: "window:1",
        workspaceID: "workspace-id", workspaceRef: "workspace:1",
        paneID: "pane-id", paneRef: "pane:1",
        surfaceID: "surface-id", surfaceRef: "surface:1"
    )
    let record = WorkspaceInventoryRecord(
        info: WorkspaceInfo(id: "workspace:1", persistentID: "workspace-id", title: "Workspace"),
        lanes: [LaneSnapshot(
            id: "surface:1", persistentID: "surface-id", title: "Lane", state: .ready,
            workspaceID: "workspace:1", workspacePersistentID: "workspace-id",
            navigationTarget: CMUXNavigationTarget(
                windowID: "window-id", windowRef: "window:1",
                workspaceID: "workspace-id", workspaceRef: "workspace:1",
                paneID: "pane-id", paneRef: "pane:1",
                surfaceID: "surface-id", surfaceRef: "surface:1"
            )
        )]
    )
    return CMUXFreshFocusAcquisition(
        snapshot: CMUXWorkspaceInventorySnapshot(records: [record], activeFocus: focus),
        isCMUXFrontmost: true,
        startedAt: date,
        finishedAt: date
    )
}

@Test func alertListProbeReportsBothKindsWithoutUserVisibleContent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var state = LaneMonitorState()
    let busy = LaneSnapshot(id: "lane", title: "PRIVATE TITLE", state: .busy, navigationTarget: probeRoute)
    let ready = LaneSnapshot(id: "lane", title: "PRIVATE TITLE", state: .ready, navigationTarget: probeRoute)
    state.establishBaseline([busy])
    state.observe([ready], now: Date())
    var tracker = InputAttentionTracker()
    tracker.observe([LaneSnapshot(
        id: "lane", persistentID: "surface-id", title: "PRIVATE INPUT", state: .inputRequired,
        workspaceID: "workspace:1", workspacePersistentID: "workspace-id",
        navigationTarget: probeRoute
    )])
    let epoch = UUID()
    let receiptState = PollReceiptState(processEpoch: epoch, appliedPollSequence: 7)
    let transactionURL = root.appendingPathComponent("watcher-transaction.json")
    try JSONEncoder().encode(WatcherTransactionState(
        laneMonitorState: state,
        inputAttentionTracker: tracker,
        pollReceiptState: receiptState
    )).write(to: transactionURL)

    let payload = try FocusedAttentionProbe.alertList(
        laneID: "lane",
        transactionStateURL: transactionURL
    )
    #expect(payload.candidates.map(\.kind) == [.completion, .inputRequired])
    #expect(payload.readiness.processEpoch == epoch)
    #expect(payload.readiness.appliedPollSequence == 7)
    #expect(payload.readiness.appliedBaselineGeneration == 0)
    let encoded = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    #expect(!encoded.contains("PRIVATE"))
    #expect(!encoded.contains("title"))
}

@Test func focusedLaneProbeAcceptsOnlyFreshExactPostReadinessReceipt() throws {
    let epoch = UUID()
    let candidate = FocusAlertIdentity(kind: .completion, laneID: "lane", navigationTarget: probeRoute)
    let receipt = try #require(FocusSuppressionReceipt(
        identity: candidate,
        processEpoch: epoch,
        proposedSequence: 8,
        observationTimestamp: Date(timeIntervalSince1970: 100)
    ))
    let state = PollReceiptState(
        processEpoch: epoch,
        appliedPollSequence: 10,
        appliedBaselineGeneration: 4,
        latestReceipts: [.completion: receipt]
    )
    let request = FocusedLaneProbeRequest(
        candidate: candidate,
        readiness: FocusProbeReadiness(
            processEpoch: epoch,
            appliedPollSequence: 7,
            appliedBaselineGeneration: 2
        )
    )
    let result = FocusedAttentionProbe.evaluate(
        request: request,
        observation: probeObservation(at: Date(timeIntervalSince1970: 101)),
        transactionState: WatcherTransactionState(pollReceiptState: state),
        reconciledAt: Date(timeIntervalSince1970: 101)
    )
    #expect(result.exactlyFocused)
    #expect(result.cmuxFrontmost)
    #expect(!result.authoritativePending)
    #expect(result.receiptAccepted)
    #expect(result.acceptedReceiptSequence == 8)
    #expect(result.appliedPollSequence == 10)
    #expect(result.appliedBaselineGeneration == 4)
}

@Test func focusedLaneProbeFailsClosedForSequenceEpochRouteAndFreshness() throws {
    let epoch = UUID()
    let candidate = FocusAlertIdentity(kind: .inputRequired, laneID: "lane", navigationTarget: probeRoute)
    let receipt = try #require(FocusSuppressionReceipt(
        identity: candidate,
        processEpoch: epoch,
        proposedSequence: 4,
        observationTimestamp: Date(timeIntervalSince1970: 100)
    ))
    let state = PollReceiptState(
        processEpoch: epoch,
        appliedPollSequence: 4,
        latestReceipts: [.inputRequired: receipt]
    )
    var tracker = InputAttentionTracker()
    tracker.observe([LaneSnapshot(
        id: "lane", title: "PRIVATE", state: .inputRequired, navigationTarget: probeRoute
    )])
    let tooLate = Date(timeIntervalSince1970: 103)
    let result = FocusedAttentionProbe.evaluate(
        request: FocusedLaneProbeRequest(
            candidate: candidate,
            readiness: FocusProbeReadiness(
                processEpoch: UUID(),
                appliedPollSequence: 4,
                appliedBaselineGeneration: 0
            )
        ),
        observation: probeObservation(at: Date(timeIntervalSince1970: 100)),
        transactionState: WatcherTransactionState(
            inputAttentionTracker: tracker,
            pollReceiptState: state
        ),
        reconciledAt: tooLate
    )
    #expect(!result.exactlyFocused)
    #expect(result.cmuxFrontmost)
    #expect(result.authoritativePending)
    #expect(!result.receiptAccepted)
}
