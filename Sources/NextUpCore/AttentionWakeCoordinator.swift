import Foundation

public struct AttentionHintIdentity: Hashable, Sendable {
    public let workspacePersistentID: String?
    public let workspaceRef: String
    public let surfacePersistentID: String?
    public let surfaceRef: String

    public init(
        workspacePersistentID: String?,
        workspaceRef: String,
        surfacePersistentID: String?,
        surfaceRef: String
    ) {
        self.workspacePersistentID = workspacePersistentID
        self.workspaceRef = workspaceRef
        self.surfacePersistentID = surfacePersistentID
        self.surfaceRef = surfaceRef
    }
}

public enum AttentionPollOrigin: Equatable, Sendable {
    case baseline
    case wake
}

public struct AttentionHintScanRequest: Equatable, Sendable {
    public let id: Int
    public let generation: Int
}

public struct AttentionPollRequest: Equatable, Sendable {
    public let id: Int
    public let origin: AttentionPollOrigin
    public let attemptIdentities: Set<AttentionHintIdentity>
}

public struct AttentionRetryRequest: Equatable, Sendable {
    public let id: Int
    public let delay: TimeInterval

    public init(id: Int, delay: TimeInterval) {
        self.id = id
        self.delay = delay
    }
}

public enum AttentionPollLaneOutcome: Equatable, Sendable {
    case inputRequired
    case nonInput
    case missing
    case readFailed
}

public struct AttentionWakeActions: Equatable, Sendable {
    public var poll: AttentionPollRequest?
    public var quarantined: Set<AttentionHintIdentity>
    public var retry: AttentionRetryRequest?

    public var retryAfter: TimeInterval? { retry?.delay }

    public init(
        poll: AttentionPollRequest? = nil,
        quarantined: Set<AttentionHintIdentity> = [],
        retry: AttentionRetryRequest? = nil
    ) {
        self.poll = poll
        self.quarantined = quarantined
        self.retry = retry
    }
}

public struct AttentionWakeCoordinator: Sendable {
    private struct ActivePoll: Sendable {
        let request: AttentionPollRequest
        var observationOnly: Set<AttentionHintIdentity>
        var tombstones: Set<AttentionHintIdentity>
    }

    private var nextPollID = 1
    private var nextScanID = 1
    private var nextRetryID = 1
    public private(set) var generation = 1
    private var running = true
    private var activeScan: AttentionHintScanRequest?
    private var activePoll: ActivePoll?
    private var warnings: Set<AttentionHintIdentity> = []
    private var queued: Set<AttentionHintIdentity> = []
    private var retryScheduled: Set<AttentionHintIdentity> = []
    private var scheduledRetries: [Int: Set<AttentionHintIdentity>] = [:]
    private var retryDue: Set<AttentionHintIdentity> = []
    private var attempts: [AttentionHintIdentity: Int] = [:]

    public init() {}

    public mutating func start() {
        guard !running else { return }
        running = true
    }

    public mutating func stop() {
        guard running else { return }
        running = false
        generation += 1
        activeScan = nil
        activePoll = nil
        warnings.removeAll()
        queued.removeAll()
        retryScheduled.removeAll()
        scheduledRetries.removeAll()
        retryDue.removeAll()
        attempts.removeAll()
    }

    public mutating func beginBaselinePoll() -> AttentionPollRequest? {
        guard running, activePoll == nil, queued.isEmpty, retryDue.isEmpty else { return nil }
        return beginPoll(origin: .baseline, attempts: [])
    }

    public mutating func beginHintScan() -> AttentionHintScanRequest? {
        guard running, activeScan == nil else { return nil }
        let request = AttentionHintScanRequest(id: nextScanID, generation: generation)
        nextScanID += 1
        activeScan = request
        return request
    }

    public mutating func completeHintScan(
        id: Int,
        generation eventGeneration: Int,
        observations: Set<AttentionHintIdentity>
    ) -> AttentionWakeActions {
        guard let scan = activeScan,
              scan.id == id,
              scan.generation == eventGeneration,
              eventGeneration == generation else { return AttentionWakeActions() }
        activeScan = nil
        return observeSuccessfulScan(observations, generation: eventGeneration)
    }

    public mutating func failHintScan(
        id: Int,
        generation eventGeneration: Int
    ) -> AttentionWakeActions {
        guard let scan = activeScan,
              scan.id == id,
              scan.generation == eventGeneration,
              eventGeneration == generation else { return AttentionWakeActions() }
        activeScan = nil
        return observeFailedScan()
    }

    public mutating func observeSuccessfulScan(
        _ observations: Set<AttentionHintIdentity>
    ) -> AttentionWakeActions {
        observeSuccessfulScan(observations, generation: generation)
    }

    public mutating func observeSuccessfulScan(
        _ observations: Set<AttentionHintIdentity>,
        generation eventGeneration: Int
    ) -> AttentionWakeActions {
        guard running, eventGeneration == generation else {
            return AttentionWakeActions()
        }
        let normalized = normalizedObservations(observations)
        let added = normalized.subtracting(warnings)
        let removed = warnings.subtracting(normalized)
        warnings = normalized
        queued.formUnion(added)
        for identity in added { attempts[identity] = 0 }
        queued.subtract(removed)
        cancelScheduledRetries(for: removed)
        retryDue.subtract(removed)
        for identity in removed { attempts.removeValue(forKey: identity) }
        if var poll = activePoll {
            poll.observationOnly.formUnion(added)
            poll.tombstones.formUnion(removed)
            activePoll = poll
            return AttentionWakeActions()
        }
        guard !queued.isEmpty else { return AttentionWakeActions() }
        return AttentionWakeActions(poll: beginWakePoll())
    }

    public mutating func observeFailedScan() -> AttentionWakeActions {
        AttentionWakeActions()
    }

    public mutating func completePoll(
        id: Int,
        outcomes: [AttentionHintIdentity: AttentionPollLaneOutcome]
    ) -> AttentionWakeActions {
        guard let completed = activePoll, completed.request.id == id else {
            return AttentionWakeActions()
        }
        activePoll = nil
        var quarantined = completed.tombstones
        var newlyScheduled: Set<AttentionHintIdentity> = []
        quarantined.formUnion(completed.observationOnly.filter {
            !completed.tombstones.contains($0) &&
            outcome(for: $0, in: outcomes) != .inputRequired
        })
        for identity in completed.observationOnly
            where !completed.tombstones.contains(identity)
                && outcome(for: identity, in: outcomes) == .inputRequired {
            queued.remove(identity)
            cancelScheduledRetries(for: [identity])
            retryDue.remove(identity)
        }
        for identity in completed.request.attemptIdentities where !completed.tombstones.contains(identity) {
            if outcome(for: identity, in: outcomes) == .inputRequired {
                cancelScheduledRetries(for: [identity])
            } else {
                quarantined.insert(identity)
                if attempts[identity, default: 0] < 2,
                   retryScheduled.insert(identity).inserted {
                    newlyScheduled.insert(identity)
                }
            }
        }
        let retry = scheduleRetry(for: newlyScheduled)
        queued.formUnion(retryDue)
        retryDue.removeAll()
        let poll = queued.isEmpty ? nil : beginWakePoll()
        return AttentionWakeActions(
            poll: poll,
            quarantined: quarantined,
            retry: retry
        )
    }

    public mutating func failPoll(id: Int) -> AttentionWakeActions {
        guard let failed = activePoll, failed.request.id == id else {
            return AttentionWakeActions()
        }
        activePoll = nil
        var newlyScheduled: Set<AttentionHintIdentity> = []
        for identity in failed.request.attemptIdentities
            where warnings.contains(identity) && !failed.tombstones.contains(identity) {
            if attempts[identity, default: 0] < 2,
               retryScheduled.insert(identity).inserted {
                newlyScheduled.insert(identity)
            }
        }
        let retry = scheduleRetry(for: newlyScheduled)
        queued.formUnion(retryDue)
        retryDue.removeAll()
        let poll = queued.isEmpty ? nil : beginWakePoll()
        return AttentionWakeActions(
            poll: poll,
            retry: retry
        )
    }

    public mutating func retryDeadline() -> AttentionWakeActions {
        guard let retryID = scheduledRetries.keys.min() else {
            return AttentionWakeActions()
        }
        return retryDeadline(id: retryID)
    }

    public mutating func retryDeadline(id: Int) -> AttentionWakeActions {
        guard running, let identities = scheduledRetries.removeValue(forKey: id) else {
            return AttentionWakeActions()
        }
        retryScheduled.subtract(identities)
        guard !identities.isEmpty else { return AttentionWakeActions() }
        if activePoll != nil {
            retryDue.formUnion(identities)
            return AttentionWakeActions()
        }
        queued.formUnion(identities)
        return AttentionWakeActions(poll: beginWakePoll())
    }

    public func attemptsStarted(for identity: AttentionHintIdentity) -> Int {
        attempts[identity, default: 0]
    }

    public func isRetryActive(id: Int) -> Bool {
        scheduledRetries[id]?.isEmpty == false
    }

    private mutating func scheduleRetry(
        for identities: Set<AttentionHintIdentity>
    ) -> AttentionRetryRequest? {
        guard !identities.isEmpty else { return nil }
        let request = AttentionRetryRequest(id: nextRetryID, delay: 0.4)
        nextRetryID += 1
        scheduledRetries[request.id] = identities
        return request
    }

    private mutating func cancelScheduledRetries(
        for identities: Set<AttentionHintIdentity>
    ) {
        guard !identities.isEmpty else { return }
        retryScheduled.subtract(identities)
        for id in Array(scheduledRetries.keys) {
            scheduledRetries[id]?.subtract(identities)
            if scheduledRetries[id]?.isEmpty == true {
                scheduledRetries.removeValue(forKey: id)
            }
        }
    }

    private func outcome(
        for identity: AttentionHintIdentity,
        in outcomes: [AttentionHintIdentity: AttentionPollLaneOutcome]
    ) -> AttentionPollLaneOutcome? {
        if let exact = outcomes[identity] { return exact }
        return outcomes.first(where: { continues(identity, as: $0.key) })?.value
    }

    private mutating func beginWakePoll() -> AttentionPollRequest {
        let identities = queued
        queued.removeAll()
        for identity in identities {
            attempts[identity, default: 0] += 1
        }
        return beginPoll(origin: .wake, attempts: identities)
    }

    private mutating func beginPoll(
        origin: AttentionPollOrigin,
        attempts identities: Set<AttentionHintIdentity>
    ) -> AttentionPollRequest {
        let request = AttentionPollRequest(
            id: nextPollID,
            origin: origin,
            attemptIdentities: identities
        )
        nextPollID += 1
        activePoll = ActivePoll(
            request: request,
            observationOnly: retryScheduled.union(retryDue).subtracting(identities),
            tombstones: []
        )
        return request
    }

    private mutating func normalizedObservations(
        _ observations: Set<AttentionHintIdentity>
    ) -> Set<AttentionHintIdentity> {
        var unmatched = warnings
        var normalized: Set<AttentionHintIdentity> = []
        for observation in observations {
            guard let prior = unmatched.first(where: { continues($0, as: observation) }) else {
                normalized.insert(observation)
                continue
            }
            unmatched.remove(prior)
            let updated = AttentionHintIdentity(
                workspacePersistentID: prior.workspacePersistentID ?? observation.workspacePersistentID,
                workspaceRef: observation.workspaceRef,
                surfacePersistentID: prior.surfacePersistentID ?? observation.surfacePersistentID,
                surfaceRef: observation.surfaceRef
            )
            replaceIdentity(prior, with: updated)
            normalized.insert(updated)
        }
        return normalized
    }

    private mutating func replaceIdentity(
        _ prior: AttentionHintIdentity,
        with updated: AttentionHintIdentity
    ) {
        guard prior != updated else { return }
        func replacing(
            _ identity: AttentionHintIdentity
        ) -> AttentionHintIdentity {
            identity == prior ? updated : identity
        }
        if warnings.remove(prior) != nil { warnings.insert(updated) }
        if queued.remove(prior) != nil { queued.insert(updated) }
        if retryScheduled.remove(prior) != nil { retryScheduled.insert(updated) }
        for id in Array(scheduledRetries.keys) where scheduledRetries[id]?.remove(prior) != nil {
            scheduledRetries[id]?.insert(updated)
        }
        if retryDue.remove(prior) != nil { retryDue.insert(updated) }
        if let count = attempts.removeValue(forKey: prior) { attempts[updated] = count }
        if var poll = activePoll {
            poll = ActivePoll(
                request: AttentionPollRequest(
                    id: poll.request.id,
                    origin: poll.request.origin,
                    attemptIdentities: Set(poll.request.attemptIdentities.map(replacing))
                ),
                observationOnly: Set(poll.observationOnly.map(replacing)),
                tombstones: Set(poll.tombstones.map(replacing))
            )
            activePoll = poll
        }
    }

    private func continues(
        _ prior: AttentionHintIdentity,
        as observation: AttentionHintIdentity
    ) -> Bool {
        componentContinues(
            knownID: prior.workspacePersistentID,
            priorRef: prior.workspaceRef,
            observedID: observation.workspacePersistentID,
            observedRef: observation.workspaceRef
        ) && componentContinues(
            knownID: prior.surfacePersistentID,
            priorRef: prior.surfaceRef,
            observedID: observation.surfacePersistentID,
            observedRef: observation.surfaceRef
        )
    }

    private func componentContinues(
        knownID: String?,
        priorRef: String,
        observedID: String?,
        observedRef: String
    ) -> Bool {
        if let knownID, let observedID {
            return knownID == observedID
        }
        return priorRef == observedRef
    }
}
