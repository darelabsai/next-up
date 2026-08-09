import Foundation

public enum FocusAlertKind: String, Codable, Equatable, Sendable {
    case completion
    case inputRequired
}

public struct FocusAlertIdentity: Codable, Equatable, Sendable {
    public let kind: FocusAlertKind
    public let laneID: String
    public let navigationTarget: CMUXNavigationTarget

    public init(kind: FocusAlertKind, laneID: String, navigationTarget: CMUXNavigationTarget) {
        self.kind = kind
        self.laneID = laneID
        self.navigationTarget = navigationTarget
    }
}

public enum FocusedAlertAcknowledgementPlanner {
    public static func laneIDsToAcknowledge(
        eligibleAlerts: [FocusAlertIdentity],
        topology: CMUXWorkspaceInventorySnapshot,
        isCMUXFrontmost: Bool,
        capturedAt: Date?,
        reconciledAt: Date
    ) -> Set<String> {
        guard isCMUXFrontmost,
              let capturedAt,
              reconciledAt.timeIntervalSince(capturedAt) >= 0,
              reconciledAt.timeIntervalSince(capturedAt) <= 2,
              let activeFocus = topology.activeFocus,
              activeFocus.hasCompleteRoute else { return [] }
        let focusedInventoryRoutes = topology.records
            .flatMap(\.lanes)
            .compactMap(\.navigationTarget)
            .filter { $0.hasCompleteRoute && activeFocus.exactlyMatches($0) }
        guard focusedInventoryRoutes.count == 1 else { return [] }

        return Set(eligibleAlerts.compactMap { alert in
            guard !alert.laneID.isEmpty, alert.navigationTarget.hasCompleteRoute else { return nil }
            return activeFocus.exactlyMatches(alert.navigationTarget) ? alert.laneID : nil
        })
    }
}

private extension CMUXActiveFocus {
    var hasCompleteRoute: Bool {
        windowID != nil && windowRef != nil &&
            workspaceID != nil && workspaceRef != nil &&
            paneID != nil && paneRef != nil &&
            surfaceID != nil && surfaceRef != nil
    }
}

private extension CMUXNavigationTarget {
    var hasCompleteRoute: Bool {
        windowID?.isEmpty == false && workspaceID?.isEmpty == false &&
            paneID?.isEmpty == false && surfaceID?.isEmpty == false
    }
}
