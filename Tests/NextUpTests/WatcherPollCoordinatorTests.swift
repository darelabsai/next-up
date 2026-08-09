import Foundation
import Testing
@testable import NextUp
@testable import NextUpCore

private let warningIdentity = AttentionHintIdentity(
    workspacePersistentID: "workspace-uuid",
    workspaceRef: "workspace:1",
    surfacePersistentID: "surface-uuid",
    surfaceRef: "surface:1"
)

private func inventory(title: String = "⚠ Hermes") -> [WorkspaceInventoryRecord] {
    [WorkspaceInventoryRecord(
        info: WorkspaceInfo(id: "workspace:1", persistentID: "workspace-uuid", title: "Work"),
        lanes: [LaneSnapshot(
            id: "surface:1", persistentID: "surface-uuid", title: title, state: .unknown,
            workspaceID: "workspace:1", workspacePersistentID: "workspace-uuid",
            workspaceTitle: "Work"
        )]
    )]
}

private func pollResult(state: LaneState, readFailed: Bool = false) -> CMUXPollResult {
    CMUXPollResult(
        workspaces: [WorkspaceInfo(id: "workspace:1", persistentID: "workspace-uuid", title: "Work")],
        inventory: inventory(),
        lanes: [LaneSnapshot(
            id: "surface:1", persistentID: "surface-uuid", title: "⚠ Hermes", state: state,
            inputRequestKind: state == .inputRequired ? .approval : nil,
            workspaceID: "workspace:1", workspacePersistentID: "workspace-uuid",
            workspaceTitle: "Work"
        )],
        readFailures: readFailed ? [warningIdentity] : []
    )
}

private func prior(_ state: LaneState = .busy) -> [LaneSnapshot] {
    [LaneSnapshot(
        id: "surface:1", persistentID: "surface-uuid", title: "Hermes", state: state,
        workspaceID: "workspace:1", workspacePersistentID: "workspace-uuid",
        workspaceTitle: "Work"
    )]
}

@Test func warningTitleQueuesFullPollWithoutApplyingTitleState() {
    var driver = WatcherPollCoordinator()
    driver.start()
    let scan = driver.beginHintScan()!

    let actions = driver.completeHintScan(
        scan, inventory: inventory(), selection: WorkspaceSelection()
    )

    #expect(actions?.poll?.origin == .wake)
    #expect(actions?.poll?.attemptIdentities == [warningIdentity])
    #expect(driver.beginBaselinePoll() == nil)
}

@Test func nonInputFirstAttemptIsQuarantinedAndSchedulesExactRetry() {
    var driver = WatcherPollCoordinator()
    driver.start()
    let scan = driver.beginHintScan()!
    let poll = driver.completeHintScan(
        scan, inventory: inventory(), selection: WorkspaceSelection()
    )!.poll!

    let completion = driver.completePoll(poll, result: pollResult(state: .ready), prior: prior())!

    #expect(completion.result.lanes.map(\.state) == [.busy])
    #expect(completion.actions.retryAfter == 0.4)
    #expect(completion.actions.quarantined == [warningIdentity])
}

@Test func corroboratedInputIsAppliedNormally() {
    var driver = WatcherPollCoordinator()
    driver.start()
    let scan = driver.beginHintScan()!
    let poll = driver.completeHintScan(
        scan, inventory: inventory(), selection: WorkspaceSelection()
    )!.poll!

    let completion = driver.completePoll(
        poll, result: pollResult(state: .inputRequired), prior: prior()
    )!

    #expect(completion.result.lanes.map(\.state) == [.inputRequired])
    #expect(completion.actions.quarantined.isEmpty)
    #expect(completion.actions.retryAfter == nil)
}

@Test func quarantiningHintedLaneStillAppliesUnrelatedLaneNormally() {
    let unrelated = LaneSnapshot(
        id: "surface:2", persistentID: "surface-uuid-2", title: "Other", state: .busy,
        workspaceID: "workspace:1", workspacePersistentID: "workspace-uuid",
        workspaceTitle: "Work"
    )
    let combinedInventory = [WorkspaceInventoryRecord(
        info: inventory()[0].info,
        lanes: inventory()[0].lanes + [unrelated]
    )]
    let result = CMUXPollResult(
        workspaces: combinedInventory.map(\.info),
        inventory: combinedInventory,
        lanes: pollResult(state: .ready).lanes + [unrelated],
        readFailures: []
    )
    var driver = WatcherPollCoordinator()
    driver.start()
    let scan = driver.beginHintScan()!
    let poll = driver.completeHintScan(
        scan, inventory: combinedInventory, selection: WorkspaceSelection()
    )!.poll!

    let completion = driver.completePoll(poll, result: result, prior: prior())!

    #expect(completion.result.lanes.first(where: { $0.id == "surface:1" })?.state == .busy)
    #expect(completion.result.lanes.first(where: { $0.id == "surface:2" })?.state == .busy)
    #expect(completion.result.quarantinedLaneIDs == ["surface:1"])
}

@Test func stopInvalidatesLateScanAndPollCompletions() {
    var scanDriver = WatcherPollCoordinator()
    scanDriver.start()
    let scan = scanDriver.beginHintScan()!
    scanDriver.stop()
    #expect(scanDriver.completeHintScan(
        scan, inventory: inventory(), selection: WorkspaceSelection()
    ) == nil)

    var pollDriver = WatcherPollCoordinator()
    pollDriver.start()
    let pollScan = pollDriver.beginHintScan()!
    let poll = pollDriver.completeHintScan(
        pollScan, inventory: inventory(), selection: WorkspaceSelection()
    )!.poll!
    pollDriver.stop()
    #expect(pollDriver.completePoll(
        poll, result: pollResult(state: .inputRequired), prior: prior()
    ) == nil)
}
