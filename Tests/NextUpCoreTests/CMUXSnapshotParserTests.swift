import Foundation
import Testing
@testable import NextUpCore

@Test func parsesEveryTerminalLaneInNamedWorkspace() throws {
    let json = """
    {"windows":[{"ref":"window:1","id":"window-uuid","workspaces":[{
      "ref":"workspace:6","id":"workspace-uuid","title":"SC (MacMini)","panes":[
      {"ref":"pane:1","id":"pane-one-uuid","surfaces":[
        {"ref":"surface:55","id":"surface-55-uuid","type":"terminal","title":"✓ Finished · gpt · ~"},
        {"ref":"surface:browser","type":"browser","title":"Docs"}
      ]},
      {"ref":"pane:2","id":"pane-two-uuid","surfaces":[
        {"ref":"surface:57","id":"surface-57-uuid","type":"terminal","title":"⏳ Working · gpt · ~"}
      ]}
    ]}]}]}
    """

    let lanes = try CMUXSnapshotParser.parse(Data(json.utf8), workspace: "workspace:6")

    #expect(lanes == [
        LaneSnapshot(
            id: "surface:55", persistentID: "surface-55-uuid",
            title: "✓ Finished · gpt · ~", state: .unknown,
            workspaceID: "workspace:6", workspacePersistentID: "workspace-uuid",
            workspaceTitle: "SC (MacMini)",
            navigationTarget: CMUXNavigationTarget(
                windowID: "window-uuid", windowRef: "window:1",
                workspaceID: "workspace-uuid", workspaceRef: "workspace:6",
                paneID: "pane-one-uuid", paneRef: "pane:1",
                surfaceID: "surface-55-uuid", surfaceRef: "surface:55"
            )
        ),
        LaneSnapshot(
            id: "surface:57", persistentID: "surface-57-uuid",
            title: "⏳ Working · gpt · ~", state: .unknown,
            workspaceID: "workspace:6", workspacePersistentID: "workspace-uuid",
            workspaceTitle: "SC (MacMini)",
            navigationTarget: CMUXNavigationTarget(
                windowID: "window-uuid", windowRef: "window:1",
                workspaceID: "workspace-uuid", workspaceRef: "workspace:6",
                paneID: "pane-two-uuid", paneRef: "pane:2",
                surfaceID: "surface-57-uuid", surfaceRef: "surface:57"
            )
        ),
    ])
}
