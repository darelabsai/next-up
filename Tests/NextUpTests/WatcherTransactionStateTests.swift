import Foundation
import Testing
import NextUpCore
@testable import NextUp

private let transactionRoute = CMUXNavigationTarget(
    windowID: "window-id", windowRef: "window-ref",
    workspaceID: "workspace-id", workspaceRef: "workspace-ref",
    paneID: "pane-id", paneRef: "pane-ref",
    surfaceID: "surface-id", surfaceRef: "surface-ref"
)

@Test func canonicalTransactionAtomicallyRestoresAcknowledgementWithAcceptedReceipt() throws {
    let url = temporaryTransactionURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let firstEpoch = UUID()
    let store = WatcherTransactionStateStore(url: url, processEpoch: firstEpoch)
    var laneState = LaneMonitorState()
    laneState.establishBaseline([
        LaneSnapshot(id: "completion", title: "Private", state: .busy)
    ])
    laneState.observe([
        LaneSnapshot(
            id: "completion", title: "Private", state: .ready,
            navigationTarget: transactionRoute
        )
    ], now: Date(timeIntervalSince1970: 100))
    var tracker = InputAttentionTracker()
    tracker.observe([
        LaneSnapshot(
            id: "input", title: "Private input", state: .inputRequired,
            navigationTarget: transactionRoute
        )
    ])
    var proposedLaneState = laneState
    var proposedTracker = tracker
    _ = WatcherFocusAcknowledgementApplicator.apply(
        laneIDs: ["completion", "input"],
        state: &proposedLaneState,
        attentionTracker: &proposedTracker
    )
    let completion = FocusAlertIdentity(
        kind: .completion, laneID: "completion", navigationTarget: transactionRoute
    )
    let input = FocusAlertIdentity(
        kind: .inputRequired, laneID: "input", navigationTarget: transactionRoute
    )

    let committed = try store.commitPoll(
        from: WatcherTransactionState(
            laneMonitorState: laneState,
            inputAttentionTracker: tracker,
            pollReceiptState: PollReceiptState(processEpoch: firstEpoch)
        ),
        pollKind: .baseline,
        laneMonitorState: proposedLaneState,
        inputAttentionTracker: proposedTracker,
        suppressionPlans: [FocusSuppressionPlan(
            suppressions: [completion, input],
            observationTimestamp: Date(timeIntervalSince1970: 101)
        )]
    )
    let restarted = WatcherTransactionStateStore(
        url: url, processEpoch: UUID()
    ).load()

    #expect(committed.pollReceiptState.appliedPollSequence == 1)
    #expect(committed.pollReceiptState.appliedBaselineGeneration == 1)
    #expect(restarted.laneMonitorState.pending.isEmpty)
    #expect(restarted.inputAttentionTracker.isAcknowledged(laneID: "input"))
    #expect(restarted.pollReceiptState.latestReceipts[.completion]?.opaqueLaneID == "completion")
    #expect(restarted.pollReceiptState.latestReceipts[.inputRequired]?.opaqueLaneID == "input")
}

@Test func canonicalPreEnrichmentAcknowledgementCanCommitWithoutFalseReceipt() throws {
    let url = temporaryTransactionURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let epoch = UUID()
    let store = WatcherTransactionStateStore(url: url, processEpoch: epoch)
    var tracker = InputAttentionTracker()
    tracker.observe([
        LaneSnapshot(id: "input", title: "Private", state: .inputRequired, navigationTarget: transactionRoute)
    ])
    var acknowledged = tracker
    acknowledged.acknowledge(laneID: "input")
    let current = WatcherTransactionState(
        laneMonitorState: LaneMonitorState(),
        inputAttentionTracker: tracker,
        pollReceiptState: PollReceiptState(processEpoch: epoch, appliedPollSequence: 4)
    )

    let committed = try store.commitAcknowledgement(
        from: current,
        laneMonitorState: current.laneMonitorState,
        inputAttentionTracker: acknowledged
    )
    let restarted = store.load()

    #expect(committed.pollReceiptState.appliedPollSequence == 4)
    #expect(committed.pollReceiptState.latestReceipts.isEmpty)
    #expect(restarted.inputAttentionTracker.isAcknowledged(laneID: "input"))
    #expect(restarted.pollReceiptState.latestReceipts.isEmpty)
}

@Test func canonicalWriterFailurePublishesNoReceiptOrAcknowledgedRestartState() throws {
    enum Expected: Error { case write }
    let url = temporaryTransactionURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let epoch = UUID()
    let goodStore = WatcherTransactionStateStore(url: url, processEpoch: epoch)
    var tracker = InputAttentionTracker()
    tracker.observe([
        LaneSnapshot(id: "input", title: "Private", state: .inputRequired, navigationTarget: transactionRoute)
    ])
    let current = WatcherTransactionState(
        laneMonitorState: LaneMonitorState(),
        inputAttentionTracker: tracker,
        pollReceiptState: PollReceiptState(processEpoch: epoch)
    )
    _ = try goodStore.commitAcknowledgement(
        from: current,
        laneMonitorState: current.laneMonitorState,
        inputAttentionTracker: tracker
    )
    var acknowledged = tracker
    acknowledged.acknowledge(laneID: "input")
    let failing = WatcherTransactionStateStore(
        url: url, processEpoch: epoch,
        atomicWriter: { _, _ in throw Expected.write }
    )
    let identity = FocusAlertIdentity(
        kind: .inputRequired, laneID: "input", navigationTarget: transactionRoute
    )

    #expect(throws: Expected.self) {
        _ = try failing.commitPoll(
            from: current,
            pollKind: .wake,
            laneMonitorState: current.laneMonitorState,
            inputAttentionTracker: acknowledged,
            suppressionPlans: [FocusSuppressionPlan(
                suppressions: [identity], observationTimestamp: Date(timeIntervalSince1970: 100)
            )]
        )
    }
    let restarted = goodStore.load()
    #expect(!restarted.inputAttentionTracker.isAcknowledged(laneID: "input"))
    #expect(restarted.pollReceiptState.latestReceipts.isEmpty)
    #expect(restarted.pollReceiptState.appliedPollSequence == 0)
}

@Test func canonicalTransactionUsesOwnerPrivateDirectoryAndFileModes() throws {
    let url = temporaryTransactionURL()
    let directory = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let epoch = UUID()
    let store = WatcherTransactionStateStore(url: url, processEpoch: epoch)

    _ = try store.commitAcknowledgement(
        from: WatcherTransactionState(pollReceiptState: PollReceiptState(processEpoch: epoch)),
        laneMonitorState: LaneMonitorState(),
        inputAttentionTracker: InputAttentionTracker()
    )

    let directoryMode = try #require(
        FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    ).intValue
    let fileMode = try #require(
        FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    ).intValue
    #expect(directoryMode == 0o700)
    #expect(fileMode == 0o600)
}

@Test func canonicalTransactionRejectsSymlinkedDirectoryWithoutMutatingItsTarget() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("nextup-transaction-symlink-\(UUID().uuidString)", isDirectory: true)
    let target = root.appendingPathComponent("unrelated", isDirectory: true)
    let directory = root.appendingPathComponent("transaction", isDirectory: true)
    let url = directory.appendingPathComponent("watcher-transaction.json")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
    let epoch = UUID()
    let store = WatcherTransactionStateStore(url: url, processEpoch: epoch)
    var rejected = false

    do {
        _ = try store.commitAcknowledgement(
            from: WatcherTransactionState(pollReceiptState: PollReceiptState(processEpoch: epoch)),
            laneMonitorState: LaneMonitorState(),
            inputAttentionTracker: InputAttentionTracker()
        )
    } catch {
        rejected = true
    }

    let targetMode = try #require(
        FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
    ).intValue
    #expect(rejected)
    #expect(targetMode == 0o755)
    #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("watcher-transaction.json").path))
}

private func temporaryTransactionURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("nextup-transaction-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("watcher-transaction.json")
}
