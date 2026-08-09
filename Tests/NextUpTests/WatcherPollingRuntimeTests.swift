import Foundation
import Testing
@testable import NextUp
@testable import NextUpCore

private final class RuntimeFake: @unchecked Sendable {
    private let lock = NSLock()
    private let fullGate = DispatchSemaphore(value: 0)
    private(set) var fullFetches = 0

    func inventory() throws -> [WorkspaceInventoryRecord] {
        [WorkspaceInventoryRecord(
            info: WorkspaceInfo(id: "workspace:1", persistentID: "workspace-uuid", title: "Work"),
            lanes: [LaneSnapshot(
                id: "surface:1", persistentID: "surface-uuid", title: "⚠ Hermes", state: .unknown,
                workspaceID: "workspace:1", workspacePersistentID: "workspace-uuid",
                workspaceTitle: "Work"
            )]
        )]
    }

    func full(_ selection: WorkspaceSelection) throws -> CMUXPollResult {
        lock.lock()
        fullFetches += 1
        lock.unlock()
        fullGate.wait()
        let inventory = try inventory()
        return CMUXPollResult(
            workspaces: inventory.map(\.info), inventory: inventory,
            lanes: [LaneSnapshot(
                id: "surface:1", persistentID: "surface-uuid", title: "⚠ Hermes", state: .ready,
                workspaceID: "workspace:1", workspacePersistentID: "workspace-uuid",
                workspaceTitle: "Work"
            )],
            readFailures: []
        )
    }

    func releaseFullFetch() { fullGate.signal() }

    func fullFetchCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return fullFetches
    }
}

private final class StaggeredRetryFake: @unchecked Sendable {
    private let lock = NSLock()
    private var inventoryFetches = 0
    private var pollFetches = 0

    func inventory() -> [WorkspaceInventoryRecord] {
        lock.lock()
        inventoryFetches += 1
        let includeSecondLane = inventoryFetches > 1
        lock.unlock()
        return [WorkspaceInventoryRecord(
            info: WorkspaceInfo(id: "workspace:1", persistentID: "workspace-uuid", title: "Work"),
            lanes: warningLanes(includeSecondLane: includeSecondLane, state: .unknown)
        )]
    }

    func full(_ selection: WorkspaceSelection) -> CMUXPollResult {
        lock.lock()
        pollFetches += 1
        let count = pollFetches
        lock.unlock()
        let includeSecondLane = count > 1
        let lanes = warningLanes(includeSecondLane: includeSecondLane, state: .ready)
        let inventory = [WorkspaceInventoryRecord(
            info: WorkspaceInfo(id: "workspace:1", persistentID: "workspace-uuid", title: "Work"),
            lanes: lanes
        )]
        return CMUXPollResult(
            workspaces: inventory.map(\.info),
            inventory: inventory,
            lanes: lanes,
            readFailures: []
        )
    }

    func pollFetchCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pollFetches
    }

    private func warningLanes(includeSecondLane: Bool, state: LaneState) -> [LaneSnapshot] {
        let ids = includeSecondLane ? [1, 2] : [1]
        return ids.map { number in
            LaneSnapshot(
                id: "surface:\(number)", persistentID: "surface-uuid-\(number)",
                title: "⚠ Hermes", state: state,
                workspaceID: "workspace:1", workspacePersistentID: "workspace-uuid",
                workspaceTitle: "Work"
            )
        }
    }
}

private final class RetryCancellationFake: @unchecked Sendable {
    private let lock = NSLock()
    private var inventoryFetches = 0
    private var pollFetches = 0

    func inventory() -> [WorkspaceInventoryRecord] {
        lock.withLock { inventoryFetches += 1 }
        let warning = lock.withLock { inventoryFetches == 1 }
        return [WorkspaceInventoryRecord(
            info: WorkspaceInfo(id: "workspace:1", persistentID: "workspace-uuid", title: "Work"),
            lanes: [LaneSnapshot(
                id: "surface:1", persistentID: "surface-uuid",
                title: warning ? "⚠ Hermes" : "Hermes", state: .unknown,
                workspaceID: "workspace:1", workspacePersistentID: "workspace-uuid",
                workspaceTitle: "Work"
            )]
        )]
    }

    func full(_ selection: WorkspaceSelection) -> CMUXPollResult {
        lock.withLock { pollFetches += 1 }
        let lane = LaneSnapshot(
            id: "surface:1", persistentID: "surface-uuid", title: "⚠ Hermes", state: .ready,
            workspaceID: "workspace:1", workspacePersistentID: "workspace-uuid",
            workspaceTitle: "Work"
        )
        let currentInventory = [WorkspaceInventoryRecord(
            info: WorkspaceInfo(id: "workspace:1", persistentID: "workspace-uuid", title: "Work"),
            lanes: [lane]
        )]
        return CMUXPollResult(
            workspaces: currentInventory.map(\.info), inventory: currentInventory,
            lanes: [lane], readFailures: []
        )
    }

    func pollFetchCount() -> Int {
        lock.withLock { pollFetches }
    }
}

private actor ApplyGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    func read() -> Int { lock.withLock { value } }
}

private final class QueuedQuarantineFake: @unchecked Sendable {
    private let lock = NSLock()
    private var pollFetches = 0

    let pollA = LaneSnapshot(
        id: "surface:1", persistentID: "surface-uuid", title: "Poll A", state: .busy,
        summary: "activity from poll A",
        workspaceID: "workspace:1", workspacePersistentID: "workspace-uuid",
        workspaceTitle: "Work"
    )

    func inventory() -> [WorkspaceInventoryRecord] {
        [WorkspaceInventoryRecord(
            info: WorkspaceInfo(id: "workspace:1", persistentID: "workspace-uuid", title: "Work"),
            lanes: [LaneSnapshot(
                id: "surface:1", persistentID: "surface-uuid", title: "⚠ Hermes", state: .unknown,
                workspaceID: "workspace:1", workspacePersistentID: "workspace-uuid",
                workspaceTitle: "Work"
            )]
        )]
    }

    func full(_ selection: WorkspaceSelection) -> CMUXPollResult {
        lock.lock()
        pollFetches += 1
        let fetch = pollFetches
        lock.unlock()
        let lane = fetch == 1 ? pollA : LaneSnapshot(
            id: "surface:1", persistentID: "surface-uuid", title: "Poll B", state: .ready,
            summary: "activity from poll B",
            workspaceID: "workspace:1", workspacePersistentID: "workspace-uuid",
            workspaceTitle: "Work"
        )
        let currentInventory = inventory()
        return CMUXPollResult(
            workspaces: currentInventory.map(\.info), inventory: currentInventory,
            lanes: [lane], readFailures: []
        )
    }
}

@Test func appStateQuarantinePreservesLaneStateWhileUnrelatedLanesApply() {
    let time = Date(timeIntervalSince1970: 100)
    let quarantinedInput = LaneSnapshot(id: "quarantined-input", title: "Approval", state: .inputRequired)
    let quarantinedReady = LaneSnapshot(id: "quarantined-ready", title: "Ready", state: .ready)
    let unrelatedBusy = LaneSnapshot(id: "unrelated", title: "Work", state: .busy)
    let unrelatedReady = LaneSnapshot(id: "unrelated", title: "Work", state: .ready)
    var state = LaneMonitorState()
    state.establishBaseline([
        LaneSnapshot(id: "quarantined-ready", title: "Work", state: .busy),
    ])
    var session = LaneObservationSession()
    var attention = InputAttentionTracker()

    WatcherPollStateApplicator.apply(
        snapshots: [quarantinedInput, unrelatedBusy],
        quarantinedLaneIDs: [],
        liveLaneIDs: [quarantinedInput.id, quarantinedReady.id, unrelatedBusy.id],
        state: &state,
        observationSession: &session,
        attentionTracker: &attention,
        now: time
    )
    attention.acknowledge(laneID: quarantinedInput.id)
    attention.markAnnounced(laneIDs: [quarantinedInput.id], at: time)

    WatcherPollStateApplicator.apply(
        snapshots: [quarantinedInput, quarantinedReady, unrelatedReady],
        quarantinedLaneIDs: [quarantinedInput.id, quarantinedReady.id],
        liveLaneIDs: [quarantinedInput.id, quarantinedReady.id, unrelatedReady.id],
        state: &state,
        observationSession: &session,
        attentionTracker: &attention,
        now: Date(timeIntervalSince1970: 110)
    )

    #expect(attention.activeLaneIDs.contains(quarantinedInput.id))
    #expect(attention.due(at: Date(timeIntervalSince1970: 400)).isEmpty)
    #expect(state.previous[quarantinedReady.id] == .busy)
    #expect(state.pending.map(\.laneID) == [unrelatedReady.id])

    WatcherPollStateApplicator.apply(
        snapshots: [quarantinedInput, quarantinedReady, unrelatedReady],
        quarantinedLaneIDs: [quarantinedInput.id],
        liveLaneIDs: [quarantinedInput.id, quarantinedReady.id, unrelatedReady.id],
        state: &state,
        observationSession: &session,
        attentionTracker: &attention,
        now: Date(timeIntervalSince1970: 120)
    )

    #expect(state.previous[quarantinedReady.id] == .ready)
    #expect(state.pending.map(\.laneID) == [unrelatedReady.id])
}

@Test func appStateRestartMakesFirstPostRestartObservationABaseline() {
    let busy = LaneSnapshot(id: "lane", title: "Work", state: .busy)
    let ready = LaneSnapshot(id: "lane", title: "Work", state: .ready)
    var state = LaneMonitorState()
    var session = LaneObservationSession()
    var attention = InputAttentionTracker()

    WatcherPollStateApplicator.apply(
        snapshots: [busy], quarantinedLaneIDs: [], liveLaneIDs: [busy.id],
        state: &state, observationSession: &session, attentionTracker: &attention,
        now: Date(timeIntervalSince1970: 100)
    )
    WatcherPollStateApplicator.resetAuthoritativeBaselines(observationSession: &session)
    WatcherPollStateApplicator.apply(
        snapshots: [ready], quarantinedLaneIDs: [], liveLaneIDs: [ready.id],
        state: &state, observationSession: &session, attentionTracker: &attention,
        now: Date(timeIntervalSince1970: 110)
    )

    #expect(state.pending.isEmpty)
    #expect(state.previous[ready.id] == .ready)
}

@MainActor
@Test func runtimeWarningHintStartsFullReadAndTitleAloneNeverAppliesInput() async throws {
    let fake = RuntimeFake()
    var appliedStates: [[LaneState]] = []
    let runtime = WatcherPollingRuntime(
        fetchInventory: fake.inventory,
        fetchPoll: fake.full,
        selection: { WorkspaceSelection() },
        priorSnapshots: { [] },
        apply: { result in
            appliedStates.append(result.lanes.map(\.state))
            return result.lanes
        }
    )
    runtime.start()

    runtime.hintScanTick()
    for _ in 0..<100 where fake.fullFetchCount() == 0 {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(fake.fullFetchCount() == 1)
    #expect(appliedStates.isEmpty)
    fake.releaseFullFetch()
    for _ in 0..<100 where appliedStates.isEmpty {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!appliedStates.flatMap { $0 }.contains(.inputRequired))
    runtime.stop()
}

@MainActor
@Test func runtimeStopCancelsSuspendedApplyBeforeMutation() async throws {
    let fake = RuntimeFake()
    var applyStarted = false
    var mutated = false
    let runtime = WatcherPollingRuntime(
        fetchInventory: fake.inventory,
        fetchPoll: fake.full,
        selection: { WorkspaceSelection() },
        priorSnapshots: { [] },
        apply: { _ in
            applyStarted = true
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return []
            }
            mutated = true
            return []
        }
    )
    runtime.start()
    runtime.baselineTick()
    for _ in 0..<100 where fake.fullFetchCount() == 0 {
        try await Task.sleep(for: .milliseconds(5))
    }
    fake.releaseFullFetch()
    for _ in 0..<100 where !applyStarted {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(applyStarted)
    runtime.stop()
    try await Task.sleep(for: .milliseconds(10))
    #expect(!mutated)
}

@MainActor
@Test func queuedQuarantinePreservesApplyTimeEnrichmentWithoutRepeatingIt() async throws {
    let fake = QueuedQuarantineFake()
    let gate = ApplyGate()
    let displayedPrior = LaneSnapshot(
        id: "surface:1", persistentID: "surface-uuid", title: "Before A", state: .ready,
        summary: "activity before poll A",
        workspaceID: "workspace:1", workspacePersistentID: "workspace-uuid",
        workspaceTitle: "Work"
    )
    let enrichedSummary = "summary enriched while applying poll A"
    var applyStarted = false
    var displayedSnapshots: [[LaneSnapshot]] = []
    var enrichmentCalls = 0
    var retries = 0
    let runtime = WatcherPollingRuntime(
        fetchInventory: fake.inventory,
        fetchPoll: fake.full,
        selection: { WorkspaceSelection() },
        priorSnapshots: { [displayedPrior] },
        apply: { result -> [LaneSnapshot] in
            applyStarted = true
            if displayedSnapshots.isEmpty { await gate.wait() }
            let eligible = result.lanes.filter { !result.quarantinedLaneIDs.contains($0.id) }
            if !eligible.isEmpty { enrichmentCalls += 1 }
            let snapshots = result.lanes.map { lane in
                guard eligible.contains(where: { $0.id == lane.id }) else { return lane }
                return LaneSnapshot(
                    id: lane.id, persistentID: lane.persistentID, title: lane.title,
                    state: lane.state, summary: enrichedSummary,
                    workspaceID: lane.workspaceID,
                    workspacePersistentID: lane.workspacePersistentID,
                    workspaceTitle: lane.workspaceTitle
                )
            }
            displayedSnapshots.append(snapshots)
            return snapshots
        },
        scheduleRetry: { _, _ in
            retries += 1
            return Task {}
        }
    )
    runtime.start()

    runtime.baselineTick()
    for _ in 0..<100 where !applyStarted {
        try await Task.sleep(for: .milliseconds(5))
    }
    runtime.hintScanTick()
    for _ in 0..<100 where retries == 0 {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(applyStarted)
    #expect(displayedSnapshots.isEmpty)
    #expect(retries == 1)
    await gate.release()
    for _ in 0..<100 where displayedSnapshots.count < 2 {
        try await Task.sleep(for: .milliseconds(5))
    }

    try #require(displayedSnapshots.count == 2)
    #expect(displayedSnapshots[0][0].summary == enrichedSummary)
    #expect(displayedSnapshots[1] == displayedSnapshots[0])
    #expect(enrichmentCalls == 1)
    runtime.stop()
}

@MainActor
@Test func runtimeStopCancelsInFlightApplyAndDropsQueuedApply() async throws {
    let fake = RuntimeFake()
    var applyStarts = 0
    var cancellations = 0
    let runtime = WatcherPollingRuntime(
        fetchInventory: fake.inventory,
        fetchPoll: fake.full,
        selection: { WorkspaceSelection() },
        priorSnapshots: { [] },
        apply: { _ in
            applyStarts += 1
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                cancellations += 1
            }
            return []
        }
    )
    runtime.start()
    runtime.baselineTick()
    for _ in 0..<100 where fake.fullFetchCount() < 1 {
        try await Task.sleep(for: .milliseconds(5))
    }
    fake.releaseFullFetch()
    for _ in 0..<100 where applyStarts < 1 {
        try await Task.sleep(for: .milliseconds(5))
    }
    runtime.baselineTick()
    for _ in 0..<100 where fake.fullFetchCount() < 2 {
        try await Task.sleep(for: .milliseconds(5))
    }
    fake.releaseFullFetch()
    try await Task.sleep(for: .milliseconds(10))

    runtime.stop()
    for _ in 0..<100 where cancellations < 1 {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(cancellations == 1)
    #expect(applyStarts == 1)
}

@MainActor
@Test func warningDisappearanceCancelsSleepingRuntimeRetryTaskPromptly() async throws {
    let fake = RetryCancellationFake()
    var retryDelay: TimeInterval?
    var retryTask: Task<Void, Never>?
    let runtime = WatcherPollingRuntime(
        fetchInventory: fake.inventory,
        fetchPoll: fake.full,
        selection: { WorkspaceSelection() },
        priorSnapshots: { [] },
        apply: { result in result.lanes },
        scheduleRetry: { delay, _ in
            retryDelay = delay
            let task = Task<Void, Never> {
                do { try await Task.sleep(for: .seconds(10)) } catch {}
            }
            retryTask = task
            return task
        }
    )
    runtime.start()

    runtime.hintScanTick()
    for _ in 0..<100 where retryTask == nil {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(retryTask != nil)
    #expect(retryDelay == 0.4)
    #expect(!retryTask!.isCancelled)

    runtime.hintScanTick()
    for _ in 0..<100 where !retryTask!.isCancelled {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(retryTask!.isCancelled)
    #expect(fake.pollFetchCount() == 1)
    runtime.stop()
}

@MainActor
@Test func staggeredWarningMissDoesNotPostponeEarlierRetryDeadline() async throws {
    let fake = StaggeredRetryFake()
    var retryDelays: [TimeInterval] = []
    var retryOperations: [@MainActor @Sendable () -> Void] = []
    var retryTasks: [Task<Void, Never>] = []
    let runtime = WatcherPollingRuntime(
        fetchInventory: fake.inventory,
        fetchPoll: fake.full,
        selection: { WorkspaceSelection() },
        priorSnapshots: { [] },
        apply: { result in result.lanes },
        scheduleRetry: { delay, operation in
            retryDelays.append(delay)
            retryOperations.append(operation)
            let task = Task<Void, Never> {
                do { try await Task.sleep(for: .seconds(10)) } catch {}
            }
            retryTasks.append(task)
            return task
        }
    )
    runtime.start()

    runtime.hintScanTick()
    for _ in 0..<100 where retryOperations.count < 1 {
        try await Task.sleep(for: .milliseconds(5))
    }
    runtime.hintScanTick()
    for _ in 0..<100 where retryOperations.count < 2 {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(retryDelays == [0.4, 0.4])
    try #require(retryTasks.count == 2)
    #expect(!retryTasks[0].isCancelled)
    retryOperations[0]()
    for _ in 0..<100 where fake.pollFetchCount() < 3 {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(fake.pollFetchCount() == 3)

    runtime.stop()
}

@MainActor
@Test func baselineCarriesRequestStartEligibilityAndOnePostFetchFreshFocus() async throws {
    let fake = RuntimeFake()
    let route = runtimeFocusRoute()
    let eligible = FocusAlertIdentity(kind: .completion, laneID: "old", navigationTarget: route)
    var eligibilityReads = 0
    let focusReads = LockedCounter()
    var applied: CMUXPollResult?
    let runtime = WatcherPollingRuntime(
        fetchInventory: fake.inventory,
        fetchPoll: fake.full,
        selection: { WorkspaceSelection() },
        priorSnapshots: { [] },
        focusEligibility: {
            eligibilityReads += 1
            return [eligible]
        },
        acquireFreshFocus: {
            focusReads.increment()
            return runtimeFreshFocus(route: route, at: Date(timeIntervalSince1970: 100))
        },
        apply: { result in
            applied = result
            return result.lanes
        }
    )
    runtime.start()

    runtime.baselineTick()
    for _ in 0..<100 where fake.fullFetchCount() == 0 {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(eligibilityReads == 1)
    #expect(focusReads.read() == 0)
    fake.releaseFullFetch()
    for _ in 0..<100 where applied == nil {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(focusReads.read() == 1)
    #expect(applied?.pollKind == .baseline)
    #expect(applied?.focusEligibility == [eligible])
    #expect(applied?.focusObservation?.finishedAt == Date(timeIntervalSince1970: 100))
    runtime.stop()
}

@MainActor
@Test func existingFocusReconcilesBeforeAsynchronousApplyWorkStarts() async throws {
    let fake = RuntimeFake()
    var events: [String] = []
    let runtime = WatcherPollingRuntime(
        fetchInventory: fake.inventory,
        fetchPoll: fake.full,
        selection: { WorkspaceSelection() },
        priorSnapshots: { [] },
        preEnrichmentReconcile: { result in
            events.append("reconcile")
            return result
        },
        apply: { result in
            events.append("apply")
            return result.lanes
        }
    )
    runtime.start()

    runtime.baselineTick()
    for _ in 0..<100 where fake.fullFetchCount() == 0 {
        try await Task.sleep(for: .milliseconds(5))
    }
    fake.releaseFullFetch()
    for _ in 0..<100 where events.count < 2 {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(events == ["reconcile", "apply"])
    runtime.stop()
}

private func runtimeFocusRoute() -> CMUXNavigationTarget {
    CMUXNavigationTarget(
        windowID: "window", windowRef: "window-ref",
        workspaceID: "workspace", workspaceRef: "workspace-ref",
        paneID: "pane", paneRef: "pane-ref",
        surfaceID: "surface", surfaceRef: "surface-ref"
    )
}

private func runtimeFreshFocus(route: CMUXNavigationTarget, at date: Date) -> CMUXFreshFocusAcquisition {
    let lane = LaneSnapshot(id: "focused", title: "Focused", state: .unknown, navigationTarget: route)
    return CMUXFreshFocusAcquisition(
        snapshot: CMUXWorkspaceInventorySnapshot(
            records: [WorkspaceInventoryRecord(
                info: WorkspaceInfo(id: "workspace-ref", persistentID: "workspace", title: "Work"),
                lanes: [lane]
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
