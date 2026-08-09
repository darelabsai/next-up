import Foundation
import NextUpCore

struct FocusProbeReadiness: Codable, Equatable, Sendable {
    let processEpoch: UUID?
    let appliedPollSequence: UInt64
    let appliedBaselineGeneration: UInt64
}

struct FocusAlertListProbePayload: Codable, Equatable, Sendable {
    let candidates: [FocusAlertIdentity]
    let readiness: FocusProbeReadiness
}

struct FocusedLaneProbeRequest: Codable, Equatable, Sendable {
    let candidate: FocusAlertIdentity
    let readiness: FocusProbeReadiness
}

struct FocusedLaneProbePayload: Codable, Equatable, Sendable {
    let exactlyFocused: Bool
    let cmuxFrontmost: Bool
    let authoritativePending: Bool
    let receiptAccepted: Bool
    let acceptedReceiptSequence: UInt64?
    let processEpoch: UUID?
    let appliedPollSequence: UInt64
    let appliedBaselineGeneration: UInt64
}

enum FocusedAttentionProbe {
    enum ProbeError: Error {
        case emptyLaneID
        case malformedState
    }

    static func alertList(
        laneID: String,
        transactionStateURL: URL
    ) throws -> FocusAlertListProbePayload {
        guard !laneID.isEmpty else { throw ProbeError.emptyLaneID }
        let transaction: WatcherTransactionState?
        if FileManager.default.fileExists(atPath: transactionStateURL.path) {
            guard let data = try? Data(contentsOf: transactionStateURL),
                  let decoded = try? JSONDecoder().decode(WatcherTransactionState.self, from: data) else {
                throw ProbeError.malformedState
            }
            transaction = decoded
        } else {
            transaction = nil
        }
        let state = transaction?.laneMonitorState ?? LaneMonitorState()
        let tracker = transaction?.inputAttentionTracker ?? InputAttentionTracker()
        var candidates: [FocusAlertIdentity] = []
        if let completion = state.pending.first(where: { $0.laneID == laneID }),
           let target = completion.navigationTarget {
            candidates.append(FocusAlertIdentity(
                kind: .completion,
                laneID: laneID,
                navigationTarget: persistentIDsOnly(target)
            ))
        }
        if tracker.activeLaneIDs.contains(laneID),
           !tracker.isAcknowledged(laneID: laneID),
           let target = tracker.navigationTarget(for: laneID) {
            candidates.append(FocusAlertIdentity(
                kind: .inputRequired,
                laneID: laneID,
                navigationTarget: persistentIDsOnly(target)
            ))
        }
        let receiptState = transaction?.pollReceiptState
        for receipt in receiptState?.latestReceipts.values ?? [:].values where receipt.opaqueLaneID == laneID {
                candidates.append(FocusAlertIdentity(
                    kind: receipt.kind,
                    laneID: laneID,
                    navigationTarget: CMUXNavigationTarget(
                        windowID: receipt.windowID,
                        windowRef: nil,
                        workspaceID: receipt.workspaceID,
                        workspaceRef: nil,
                        paneID: receipt.paneID,
                        paneRef: nil,
                        surfaceID: receipt.surfaceID,
                        surfaceRef: nil
                    )
                ))
        }
        var uniqueCandidates: [FocusAlertIdentity] = []
        for candidate in candidates.sorted(by: candidateOrder) where
            !uniqueCandidates.contains(where: { sameIdentity($0, candidate) }) {
            uniqueCandidates.append(candidate)
        }
        return FocusAlertListProbePayload(
            candidates: uniqueCandidates,
            readiness: FocusProbeReadiness(
                processEpoch: receiptState?.processEpoch,
                appliedPollSequence: receiptState?.appliedPollSequence ?? 0,
                appliedBaselineGeneration: receiptState?.appliedBaselineGeneration ?? 0
            )
        )
    }

    static func evaluate(
        request: FocusedLaneProbeRequest,
        observation: CMUXFreshFocusAcquisition?,
        transactionState: WatcherTransactionState?,
        reconciledAt: Date
    ) -> FocusedLaneProbePayload {
        let exactlyFocused = !WatcherFocusReconciliation.plan(
            eligibleAlerts: [request.candidate],
            observation: observation,
            reconciledAt: reconciledAt
        ).suppressions.isEmpty
        let receiptState = transactionState?.pollReceiptState
        let receipt = receiptState?.latestReceipts[request.candidate.kind]
        let authoritativePending = transactionState.map {
            WatcherFocusReconciliation.eligibleAlerts(
                state: $0.laneMonitorState,
                attentionTracker: $0.inputAttentionTracker
            ).contains { WatcherFocusReconciliation.sameIdentity($0, request.candidate) }
        } ?? false
        let durablyAcknowledged = transactionState.map {
            _ in !authoritativePending
        } ?? false
        let receiptAccepted = request.readiness.processEpoch != nil &&
            durablyAcknowledged &&
            request.readiness.processEpoch == receiptState?.processEpoch &&
            receipt?.processEpoch == receiptState?.processEpoch &&
            receipt?.matches(request.candidate) == true &&
            receipt?.nativeRequestScheduled == false &&
            receipt?.voiceScheduled == false &&
            (receipt?.proposedSequence ?? 0) > request.readiness.appliedPollSequence &&
            (receipt?.proposedSequence ?? UInt64.max) <= (receiptState?.appliedPollSequence ?? 0)
        return FocusedLaneProbePayload(
            exactlyFocused: exactlyFocused,
            cmuxFrontmost: observation?.isCMUXFrontmost == true,
            authoritativePending: authoritativePending,
            receiptAccepted: receiptAccepted,
            acceptedReceiptSequence: receiptAccepted ? receipt?.proposedSequence : nil,
            processEpoch: receiptState?.processEpoch,
            appliedPollSequence: receiptState?.appliedPollSequence ?? 0,
            appliedBaselineGeneration: receiptState?.appliedBaselineGeneration ?? 0
        )
    }

    static func persistedTransactionState(at url: URL) -> WatcherTransactionState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WatcherTransactionState.self, from: data)
    }

    private static func persistentIDsOnly(_ target: CMUXNavigationTarget) -> CMUXNavigationTarget {
        CMUXNavigationTarget(
            windowID: target.windowID,
            windowRef: nil,
            workspaceID: target.workspaceID,
            workspaceRef: nil,
            paneID: target.paneID,
            paneRef: nil,
            surfaceID: target.surfaceID,
            surfaceRef: nil
        )
    }

    private static func candidateOrder(_ lhs: FocusAlertIdentity, _ rhs: FocusAlertIdentity) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.laneID < rhs.laneID
    }

    private static func sameIdentity(_ lhs: FocusAlertIdentity, _ rhs: FocusAlertIdentity) -> Bool {
        lhs.kind == rhs.kind && lhs.laneID == rhs.laneID &&
            lhs.navigationTarget.windowID == rhs.navigationTarget.windowID &&
            lhs.navigationTarget.workspaceID == rhs.navigationTarget.workspaceID &&
            lhs.navigationTarget.paneID == rhs.navigationTarget.paneID &&
            lhs.navigationTarget.surfaceID == rhs.navigationTarget.surfaceID
    }
}
