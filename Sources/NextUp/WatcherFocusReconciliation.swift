import Foundation
import NextUpCore

struct FocusSuppressionPlan: Equatable, Sendable {
    let suppressions: [FocusAlertIdentity]
    let observationTimestamp: Date?

    static let empty = FocusSuppressionPlan(suppressions: [], observationTimestamp: nil)
}

enum WatcherFocusReconciliation {
    static func eligibleAlerts(
        state: LaneMonitorState,
        attentionTracker: InputAttentionTracker
    ) -> [FocusAlertIdentity] {
        var alerts: [FocusAlertIdentity] = state.pending.compactMap { completion in
            guard let target = completion.navigationTarget else { return nil }
            return FocusAlertIdentity(
                kind: .completion,
                laneID: completion.laneID,
                navigationTarget: target
            )
        }
        alerts.append(contentsOf: attentionTracker.activeLaneIDs.compactMap { laneID in
            guard !attentionTracker.isAcknowledged(laneID: laneID),
                  let target = attentionTracker.navigationTarget(for: laneID) else { return nil }
            return FocusAlertIdentity(
                kind: .inputRequired,
                laneID: laneID,
                navigationTarget: target
            )
        })
        return alerts.sorted(by: ordered)
    }

    static func plan(
        eligibleAlerts: [FocusAlertIdentity],
        observation: CMUXFreshFocusAcquisition?,
        reconciledAt: Date
    ) -> FocusSuppressionPlan {
        guard !eligibleAlerts.isEmpty, let observation else { return .empty }
        let suppressions = eligibleAlerts.filter { identity in
            FocusedAlertAcknowledgementPlanner.laneIDsToAcknowledge(
                eligibleAlerts: [identity],
                topology: observation.snapshot,
                isCMUXFrontmost: observation.isCMUXFrontmost,
                capturedAt: observation.startedAt,
                reconciledAt: reconciledAt
            ).contains(identity.laneID)
        }
        guard !suppressions.isEmpty else { return .empty }
        return FocusSuppressionPlan(
            suppressions: suppressions,
            observationTimestamp: observation.startedAt
        )
    }

    static func planNewSuppressions(
        previousAlerts: [FocusAlertIdentity],
        currentAlerts: [FocusAlertIdentity],
        reconciledAt: Date,
        acquireFreshFocus: () -> CMUXFreshFocusAcquisition?
    ) -> FocusSuppressionPlan {
        let newAlerts = newlyCreatedAlerts(
            previousAlerts: previousAlerts,
            currentAlerts: currentAlerts
        )
        guard !newAlerts.isEmpty else { return .empty }
        return plan(
            eligibleAlerts: newAlerts,
            observation: acquireFreshFocus(),
            reconciledAt: reconciledAt
        )
    }

    static func newlyCreatedAlerts(
        previousAlerts: [FocusAlertIdentity],
        currentAlerts: [FocusAlertIdentity]
    ) -> [FocusAlertIdentity] {
        currentAlerts.filter { current in
            !previousAlerts.contains { sameIdentity($0, current) }
        }
    }

    static func persistedReceiptLaneIDs(
        in receiptState: PollReceiptState,
        eligibleAlerts: [FocusAlertIdentity]
    ) -> Set<String> {
        Set(eligibleAlerts.compactMap { identity in
            receiptState.latestReceipts[identity.kind]?.matches(identity) == true
                ? identity.laneID : nil
        })
    }

    static func sameIdentity(_ lhs: FocusAlertIdentity, _ rhs: FocusAlertIdentity) -> Bool {
        lhs.kind == rhs.kind && lhs.laneID == rhs.laneID &&
            lhs.navigationTarget.windowID == rhs.navigationTarget.windowID &&
            lhs.navigationTarget.workspaceID == rhs.navigationTarget.workspaceID &&
            lhs.navigationTarget.paneID == rhs.navigationTarget.paneID &&
            lhs.navigationTarget.surfaceID == rhs.navigationTarget.surfaceID
    }

    private static func ordered(_ lhs: FocusAlertIdentity, _ rhs: FocusAlertIdentity) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.laneID < rhs.laneID
    }
}
