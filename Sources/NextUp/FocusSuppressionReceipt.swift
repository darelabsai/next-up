import Foundation
import NextUpCore

enum WatcherPollKind: String, Codable, Equatable, Sendable {
    case baseline
    case wake
    case retry
}

struct FocusSuppressionReceipt: Codable, Equatable, Sendable {
    let kind: FocusAlertKind
    let opaqueLaneID: String
    let windowID: String
    let workspaceID: String
    let paneID: String
    let surfaceID: String
    let processEpoch: UUID
    let proposedSequence: UInt64
    let observationTimestamp: Date
    let nativeRequestScheduled: Bool
    let voiceScheduled: Bool

    init?(
        identity: FocusAlertIdentity,
        processEpoch: UUID,
        proposedSequence: UInt64,
        observationTimestamp: Date
    ) {
        guard !identity.laneID.isEmpty,
              let windowID = identity.navigationTarget.windowID,
              let workspaceID = identity.navigationTarget.workspaceID,
              let paneID = identity.navigationTarget.paneID,
              let surfaceID = identity.navigationTarget.surfaceID else { return nil }
        kind = identity.kind
        opaqueLaneID = identity.laneID
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.surfaceID = surfaceID
        self.processEpoch = processEpoch
        self.proposedSequence = proposedSequence
        self.observationTimestamp = observationTimestamp
        nativeRequestScheduled = false
        voiceScheduled = false
    }

    func matches(_ identity: FocusAlertIdentity) -> Bool {
        kind == identity.kind &&
            opaqueLaneID == identity.laneID &&
            windowID == identity.navigationTarget.windowID &&
            workspaceID == identity.navigationTarget.workspaceID &&
            paneID == identity.navigationTarget.paneID &&
            surfaceID == identity.navigationTarget.surfaceID
    }
}

struct PollReceiptState: Codable, Equatable, Sendable {
    var processEpoch: UUID
    var appliedPollSequence: UInt64
    var appliedBaselineGeneration: UInt64
    var latestReceipts: [FocusAlertKind: FocusSuppressionReceipt]

    init(
        processEpoch: UUID,
        appliedPollSequence: UInt64 = 0,
        appliedBaselineGeneration: UInt64 = 0,
        latestReceipts: [FocusAlertKind: FocusSuppressionReceipt] = [:]
    ) {
        self.processEpoch = processEpoch
        self.appliedPollSequence = appliedPollSequence
        self.appliedBaselineGeneration = appliedBaselineGeneration
        self.latestReceipts = latestReceipts
    }

    private enum CodingKeys: String, CodingKey {
        case processEpoch, appliedPollSequence, appliedBaselineGeneration
        case completionReceipt, inputRequiredReceipt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        processEpoch = try container.decode(UUID.self, forKey: .processEpoch)
        appliedPollSequence = try container.decodeIfPresent(UInt64.self, forKey: .appliedPollSequence) ?? 0
        appliedBaselineGeneration = try container.decodeIfPresent(UInt64.self, forKey: .appliedBaselineGeneration) ?? 0
        latestReceipts = [:]
        if let receipt = try container.decodeIfPresent(FocusSuppressionReceipt.self, forKey: .completionReceipt) {
            latestReceipts[.completion] = receipt
        }
        if let receipt = try container.decodeIfPresent(FocusSuppressionReceipt.self, forKey: .inputRequiredReceipt) {
            latestReceipts[.inputRequired] = receipt
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(processEpoch, forKey: .processEpoch)
        try container.encode(appliedPollSequence, forKey: .appliedPollSequence)
        try container.encode(appliedBaselineGeneration, forKey: .appliedBaselineGeneration)
        try container.encodeIfPresent(latestReceipts[.completion], forKey: .completionReceipt)
        try container.encodeIfPresent(latestReceipts[.inputRequired], forKey: .inputRequiredReceipt)
    }
}

struct PollReceiptStateStore: Sendable {
    typealias AtomicWriter = @Sendable (Data, URL) throws -> Void

    let url: URL
    let processEpoch: UUID
    private let atomicWriter: AtomicWriter

    init(
        url: URL,
        processEpoch: UUID = UUID(),
        atomicWriter: @escaping AtomicWriter = { data, url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.url = url
        self.processEpoch = processEpoch
        self.atomicWriter = atomicWriter
    }

    func load() -> PollReceiptState {
        guard let data = try? Data(contentsOf: url),
              var restored = try? JSONDecoder().decode(PollReceiptState.self, from: data) else {
            return PollReceiptState(processEpoch: processEpoch)
        }
        restored.processEpoch = processEpoch
        return restored
    }

    func commit(
        from current: PollReceiptState,
        pollKind: WatcherPollKind,
        suppressions: [FocusAlertIdentity],
        observationTimestamp: Date?
    ) throws -> PollReceiptState {
        let plans: [FocusSuppressionPlan]
        if suppressions.isEmpty {
            plans = []
        } else {
            plans = [FocusSuppressionPlan(
                suppressions: suppressions,
                observationTimestamp: observationTimestamp
            )]
        }
        return try commit(from: current, pollKind: pollKind, suppressionPlans: plans)
    }

    func commit(
        from current: PollReceiptState,
        pollKind: WatcherPollKind,
        suppressionPlans: [FocusSuppressionPlan]
    ) throws -> PollReceiptState {
        var proposed = current
        proposed.processEpoch = processEpoch
        proposed.appliedPollSequence += 1
        if pollKind == .baseline {
            proposed.appliedBaselineGeneration += 1
        }
        for plan in suppressionPlans where !plan.suppressions.isEmpty {
            guard let observationTimestamp = plan.observationTimestamp else {
                throw ReceiptError.missingObservationTimestamp
            }
            for identity in plan.suppressions.sorted(by: Self.receiptOrder) {
                guard let receipt = FocusSuppressionReceipt(
                    identity: identity,
                    processEpoch: processEpoch,
                    proposedSequence: proposed.appliedPollSequence,
                    observationTimestamp: observationTimestamp
                ) else { continue }
                proposed.latestReceipts[identity.kind] = receipt
            }
        }
        let data = try JSONEncoder().encode(proposed)
        try atomicWriter(data, url)
        return proposed
    }

    private static func receiptOrder(_ lhs: FocusAlertIdentity, _ rhs: FocusAlertIdentity) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.laneID < rhs.laneID
    }

    enum ReceiptError: Error {
        case missingObservationTimestamp
    }
}
