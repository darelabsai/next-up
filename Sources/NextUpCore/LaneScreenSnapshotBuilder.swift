import Foundation

public enum LaneScreenSnapshotBuilder {
    public static func build(
        id: String,
        persistentID: String? = nil,
        title: String,
        workspaceID: String = "",
        workspacePersistentID: String? = nil,
        workspaceTitle: String = "",
        machine: String = "mac-air",
        hermesProfile: String = "default",
        navigationTarget: CMUXNavigationTarget? = nil,
        screen: String,
        extractSummary: (String) -> String? = CompletionSummaryExtractor.extract
    ) -> LaneSnapshot {
        let classification = SurfaceContentClassifier.classification(
            screen,
            titleHasWarningHint: AttentionWarningScanner.hasLeadingWarningTitle(title)
        )
        let visibleSummary = classification.state == .inputRequired
            ? nil
            : extractSummary(screen)
        return LaneSnapshot(
            id: id,
            persistentID: persistentID,
            title: title,
            state: classification.state,
            inputRequestKind: classification.inputRequestKind,
            summary: visibleSummary,
            matchingSnippet: visibleSummary,
            workspaceID: workspaceID,
            workspacePersistentID: workspacePersistentID,
            workspaceTitle: workspaceTitle,
            machine: machine,
            hermesProfile: hermesProfile,
            navigationTarget: navigationTarget
        )
    }
}
