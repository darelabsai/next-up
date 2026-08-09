import Foundation

public enum AttentionWarningScanner {
    public static func hasLeadingWarningTitle(_ title: String) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars.first?.value == 0x26A0
    }

    public static func hints(
        in inventory: [WorkspaceInventoryRecord],
        selection: WorkspaceSelection
    ) -> Set<AttentionHintIdentity> {
        Set(inventory.flatMap { workspace -> [AttentionHintIdentity] in
            guard selection.isSelected(workspace.info.id) else { return [] }
            return workspace.lanes.compactMap { lane in
                guard hasLeadingWarningTitle(lane.title) else { return nil }
                return AttentionHintIdentity(
                    workspacePersistentID: workspace.info.persistentID,
                    workspaceRef: workspace.info.id,
                    surfacePersistentID: lane.persistentID,
                    surfaceRef: lane.id
                )
            }
        })
    }
}
