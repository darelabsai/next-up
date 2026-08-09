import Testing
@testable import NextUpCore

@Test func warningScannerReturnsOnlySelectedLeadingWarningTitles() {
    let selected = WorkspaceInventoryRecord(
        info: WorkspaceInfo(id: "workspace:1", persistentID: "workspace-a", title: "Selected"),
        lanes: [
            LaneSnapshot(id: "surface:1", persistentID: "surface-a", title: "⚠ Approval", state: .unknown),
            LaneSnapshot(id: "surface:2", persistentID: "surface-b", title: "⚠️ Question", state: .unknown),
            LaneSnapshot(id: "surface:3", persistentID: "surface-c", title: "Working ⚠ later", state: .unknown),
            LaneSnapshot(id: "surface:4", persistentID: "surface-d", title: "⏳ Confirm", state: .unknown),
        ]
    )
    let excluded = WorkspaceInventoryRecord(
        info: WorkspaceInfo(id: "workspace:2", persistentID: "workspace-b", title: "Excluded"),
        lanes: [
            LaneSnapshot(id: "surface:5", persistentID: "surface-e", title: "⚠ Secret", state: .unknown),
        ]
    )
    let selection = WorkspaceSelection(excludedWorkspaceIDs: ["workspace:2"])

    let hints = AttentionWarningScanner.hints(
        in: [selected, excluded],
        selection: selection
    )

    #expect(hints == [
        AttentionHintIdentity(
            workspacePersistentID: "workspace-a", workspaceRef: "workspace:1",
            surfacePersistentID: "surface-a", surfaceRef: "surface:1"
        ),
        AttentionHintIdentity(
            workspacePersistentID: "workspace-a", workspaceRef: "workspace:1",
            surfacePersistentID: "surface-b", surfaceRef: "surface:2"
        ),
    ])
}
