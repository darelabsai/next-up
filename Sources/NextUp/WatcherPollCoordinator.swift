import Foundation
import NextUpCore

struct WatcherPollCompletion: Sendable {
    let result: CMUXPollResult
    let actions: AttentionWakeActions
}

struct WatcherPollCoordinator: Sendable {
    private var coordinator: AttentionWakeCoordinator
    private var activePollID: Int?
    private var trackedHints: Set<AttentionHintIdentity> = []
    private var running = false

    init() {
        var coordinator = AttentionWakeCoordinator()
        coordinator.stop()
        self.coordinator = coordinator
    }

    mutating func start() {
        guard !running else { return }
        running = true
        coordinator.start()
    }

    mutating func stop() {
        guard running else { return }
        running = false
        coordinator.stop()
        activePollID = nil
        trackedHints.removeAll()
    }

    mutating func beginHintScan() -> AttentionHintScanRequest? {
        guard running else { return nil }
        return coordinator.beginHintScan()
    }

    mutating func completeHintScan(
        _ request: AttentionHintScanRequest,
        inventory: [WorkspaceInventoryRecord],
        selection: WorkspaceSelection
    ) -> AttentionWakeActions? {
        guard running else { return nil }
        let observations = AttentionWarningScanner.hints(in: inventory, selection: selection)
        trackedHints = normalized(observations, against: trackedHints)
        let actions = coordinator.completeHintScan(
            id: request.id,
            generation: request.generation,
            observations: observations
        )
        register(actions.poll)
        return actions
    }

    mutating func failHintScan(_ request: AttentionHintScanRequest) -> AttentionWakeActions? {
        guard running else { return nil }
        let actions = coordinator.failHintScan(id: request.id, generation: request.generation)
        register(actions.poll)
        return actions
    }

    mutating func beginBaselinePoll() -> AttentionPollRequest? {
        guard running else { return nil }
        let request = coordinator.beginBaselinePoll()
        register(request)
        return request
    }

    mutating func completePoll(
        _ request: AttentionPollRequest,
        result: CMUXPollResult,
        prior: [LaneSnapshot]
    ) -> WatcherPollCompletion? {
        guard running, activePollID == request.id else { return nil }
        let identities = trackedHints.union(request.attemptIdentities)
        let outcomes = Dictionary(uniqueKeysWithValues: identities.map {
            ($0, outcome(for: $0, in: result))
        })
        let actions = coordinator.completePoll(id: request.id, outcomes: outcomes)
        activePollID = nil
        register(actions.poll)
        return WatcherPollCompletion(
            result: replacingQuarantined(
                actions.quarantined,
                in: result,
                with: prior
            ),
            actions: actions
        )
    }

    mutating func failPoll(_ request: AttentionPollRequest) -> AttentionWakeActions? {
        guard running, activePollID == request.id else { return nil }
        let actions = coordinator.failPoll(id: request.id)
        activePollID = nil
        register(actions.poll)
        return actions
    }

    mutating func retryDeadline() -> AttentionWakeActions? {
        guard running else { return nil }
        let actions = coordinator.retryDeadline()
        register(actions.poll)
        return actions
    }

    mutating func retryDeadline(id: Int) -> AttentionWakeActions? {
        guard running else { return nil }
        let actions = coordinator.retryDeadline(id: id)
        register(actions.poll)
        return actions
    }

    func isRetryActive(id: Int) -> Bool {
        coordinator.isRetryActive(id: id)
    }

    private mutating func register(_ request: AttentionPollRequest?) {
        if let request { activePollID = request.id }
    }

    private func outcome(
        for identity: AttentionHintIdentity,
        in result: CMUXPollResult
    ) -> AttentionPollLaneOutcome {
        guard result.inventory.contains(where: { workspace in
            workspace.lanes.contains { lane in matches(identity, workspace: workspace.info, lane: lane) }
        }) else { return .missing }
        if result.readFailures.contains(where: { matches(identity, other: $0) }) {
            return .readFailed
        }
        guard let lane = result.lanes.first(where: { lane in
            matches(identity, lane: lane)
        }) else { return .missing }
        return lane.state == .inputRequired ? .inputRequired : .nonInput
    }

    private func replacingQuarantined(
        _ quarantined: Set<AttentionHintIdentity>,
        in result: CMUXPollResult,
        with prior: [LaneSnapshot]
    ) -> CMUXPollResult {
        guard !quarantined.isEmpty else { return result }
        var usedPriorIDs: Set<String> = []
        var lanes = result.lanes.compactMap { lane -> LaneSnapshot? in
            guard quarantined.contains(where: { matches($0, lane: lane) }) else { return lane }
            guard let old = prior.first(where: { matchesLane($0, lane) }) else { return nil }
            usedPriorIDs.insert(old.id)
            return old
        }
        for old in prior where !usedPriorIDs.contains(old.id) &&
            quarantined.contains(where: { matches($0, lane: old) }) {
            lanes.append(old)
        }
        return CMUXPollResult(
            workspaces: result.workspaces,
            inventory: result.inventory,
            lanes: lanes,
            readFailures: result.readFailures,
            quarantinedLaneIDs: Set(prior.filter { old in
                quarantined.contains(where: { matches($0, lane: old) })
            }.map(\.id))
        )
    }

    private func matches(
        _ identity: AttentionHintIdentity,
        workspace: WorkspaceInfo,
        lane: LaneSnapshot
    ) -> Bool {
        componentMatches(
            identity.workspacePersistentID, identity.workspaceRef,
            workspace.persistentID, workspace.id
        ) && componentMatches(
            identity.surfacePersistentID, identity.surfaceRef,
            lane.persistentID, lane.id
        )
    }

    private func matches(_ identity: AttentionHintIdentity, lane: LaneSnapshot) -> Bool {
        componentMatches(
            identity.workspacePersistentID, identity.workspaceRef,
            lane.workspacePersistentID, lane.workspaceID
        ) && componentMatches(
            identity.surfacePersistentID, identity.surfaceRef,
            lane.persistentID, lane.id
        )
    }

    private func matches(_ identity: AttentionHintIdentity, other: AttentionHintIdentity) -> Bool {
        componentMatches(
            identity.workspacePersistentID, identity.workspaceRef,
            other.workspacePersistentID, other.workspaceRef
        ) && componentMatches(
            identity.surfacePersistentID, identity.surfaceRef,
            other.surfacePersistentID, other.surfaceRef
        )
    }

    private func matchesLane(_ lhs: LaneSnapshot, _ rhs: LaneSnapshot) -> Bool {
        componentMatches(lhs.workspacePersistentID, lhs.workspaceID, rhs.workspacePersistentID, rhs.workspaceID) &&
            componentMatches(lhs.persistentID, lhs.id, rhs.persistentID, rhs.id)
    }

    private func componentMatches(_ lhsID: String?, _ lhsRef: String, _ rhsID: String?, _ rhsRef: String) -> Bool {
        if let lhsID, let rhsID { return lhsID == rhsID }
        return lhsRef == rhsRef
    }

    private func normalized(
        _ observations: Set<AttentionHintIdentity>,
        against previous: Set<AttentionHintIdentity>
    ) -> Set<AttentionHintIdentity> {
        var unmatched = previous
        return Set(observations.map { observation in
            guard let prior = unmatched.first(where: { matches($0, other: observation) }) else {
                return observation
            }
            unmatched.remove(prior)
            return AttentionHintIdentity(
                workspacePersistentID: prior.workspacePersistentID ?? observation.workspacePersistentID,
                workspaceRef: observation.workspaceRef,
                surfacePersistentID: prior.surfacePersistentID ?? observation.surfacePersistentID,
                surfaceRef: observation.surfaceRef
            )
        })
    }
}

@MainActor
final class WatcherPollingRuntime {
    typealias InventoryFetcher = @Sendable () throws -> [WorkspaceInventoryRecord]
    typealias PollFetcher = @Sendable (WorkspaceSelection) throws -> CMUXPollResult
    typealias RetryScheduler = @MainActor (
        TimeInterval,
        @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never>

    private var driver = WatcherPollCoordinator()
    private let fetchInventory: InventoryFetcher
    private let fetchPoll: PollFetcher
    private let selection: @MainActor () -> WorkspaceSelection
    private let priorSnapshots: @MainActor () -> [LaneSnapshot]
    private let apply: @MainActor (CMUXPollResult) async -> [LaneSnapshot]
    private let failed: @MainActor (String) -> Void
    private let scheduleRetry: RetryScheduler
    private var retryTasks: [Int: Task<Void, Never>] = [:]
    private var applyQueue: [CMUXPollResult] = []
    private var applyTask: Task<Void, Never>?
    private var projectedSnapshots: [LaneSnapshot]?
    private var generation = 0

    init(
        fetchInventory: @escaping InventoryFetcher,
        fetchPoll: @escaping PollFetcher,
        selection: @escaping @MainActor () -> WorkspaceSelection,
        priorSnapshots: @escaping @MainActor () -> [LaneSnapshot],
        apply: @escaping @MainActor (CMUXPollResult) async -> [LaneSnapshot],
        failed: @escaping @MainActor (String) -> Void = { _ in },
        scheduleRetry: @escaping RetryScheduler = WatcherPollingRuntime.defaultRetryScheduler
    ) {
        self.fetchInventory = fetchInventory
        self.fetchPoll = fetchPoll
        self.selection = selection
        self.priorSnapshots = priorSnapshots
        self.apply = apply
        self.failed = failed
        self.scheduleRetry = scheduleRetry
    }

    func start() {
        driver.start()
    }

    func stop() {
        generation += 1
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
        applyTask?.cancel()
        applyTask = nil
        applyQueue.removeAll()
        projectedSnapshots = nil
        driver.stop()
    }

    func hintScanTick() {
        guard let request = driver.beginHintScan() else { return }
        let fetchInventory = self.fetchInventory
        let selection = self.selection()
        Task { [weak self] in
            let result = await Task.detached { () -> Result<[WorkspaceInventoryRecord], Error> in
                Result { try fetchInventory() }
            }.value
            guard let self else { return }
            switch result {
            case let .success(inventory):
                guard let actions = self.driver.completeHintScan(
                    request, inventory: inventory, selection: selection
                ) else { return }
                self.service(actions)
            case let .failure(error):
                guard let actions = self.driver.failHintScan(request) else { return }
                self.service(actions)
                self.failed(error.localizedDescription)
            }
        }
    }

    func baselineTick() {
        guard let request = driver.beginBaselinePoll() else { return }
        launch(request)
    }

    private func launch(_ request: AttentionPollRequest) {
        let fetchPoll = self.fetchPoll
        let selection = self.selection()
        Task { [weak self] in
            let result = await Task.detached { () -> Result<CMUXPollResult, Error> in
                Result { try fetchPoll(selection) }
            }.value
            guard let self else { return }
            switch result {
            case let .success(result):
                guard let completion = self.driver.completePoll(
                    request,
                    result: result,
                    prior: self.projectedSnapshots ?? self.priorSnapshots()
                ) else { return }
                self.service(completion.actions)
                self.enqueueApply(completion.result)
            case let .failure(error):
                guard let actions = self.driver.failPoll(request) else { return }
                self.service(actions)
                self.failed(error.localizedDescription)
            }
        }
    }

    private func service(_ actions: AttentionWakeActions) {
        for id in Array(retryTasks.keys) where !driver.isRetryActive(id: id) {
            retryTasks.removeValue(forKey: id)?.cancel()
        }
        if let poll = actions.poll { launch(poll) }
        if let retry = actions.retry {
            retryTasks[retry.id] = scheduleRetry(retry.delay) { [weak self] in
                guard let self else { return }
                self.retryTasks.removeValue(forKey: retry.id)
                guard let due = self.driver.retryDeadline(id: retry.id) else { return }
                self.service(due)
            }
        }
    }

    private func enqueueApply(_ result: CMUXPollResult) {
        projectedSnapshots = result.lanes
        applyQueue.append(result)
        guard applyTask == nil else { return }
        let eventGeneration = generation
        applyTask = Task { @MainActor [weak self] in
            await self?.drainApplyQueue(generation: eventGeneration)
        }
    }

    private func drainApplyQueue(generation eventGeneration: Int) async {
        while !applyQueue.isEmpty {
            guard generation == eventGeneration, !Task.isCancelled else { return }
            let result = applyQueue.removeFirst()
            let appliedSnapshots = await apply(result)
            guard generation == eventGeneration, !Task.isCancelled else { return }
            rebaseQueuedResults(on: appliedSnapshots)
        }
        guard generation == eventGeneration, !Task.isCancelled else { return }
        projectedSnapshots = nil
        applyTask = nil
    }

    private func rebasingQuarantinedLanes(
        in result: CMUXPollResult,
        on snapshots: [LaneSnapshot]
    ) -> CMUXPollResult {
        guard !result.quarantinedLaneIDs.isEmpty else { return result }
        let snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        let lanes = result.lanes.map { lane in
            guard result.quarantinedLaneIDs.contains(lane.id) else { return lane }
            return snapshotsByID[lane.id] ?? lane
        }
        return CMUXPollResult(
            workspaces: result.workspaces,
            inventory: result.inventory,
            lanes: lanes,
            readFailures: result.readFailures,
            quarantinedLaneIDs: result.quarantinedLaneIDs
        )
    }

    private func rebaseQueuedResults(on appliedSnapshots: [LaneSnapshot]) {
        var projection = appliedSnapshots
        for index in applyQueue.indices {
            let rebased = rebasingQuarantinedLanes(in: applyQueue[index], on: projection)
            applyQueue[index] = rebased
            projection = rebased.lanes
        }
        projectedSnapshots = projection
    }

    private static func defaultRetryScheduler(
        _ delay: TimeInterval,
        _ operation: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(delay))
                operation()
            } catch {}
        }
    }
}
