import Foundation
import Testing
@testable import NextUpCore

@Test func parsesAllWorkspacesAndTheirTerminalSurfaces() throws {
    let json = """
    {"windows":[
      {"ref":"window:1","id":"AIR-WINDOW-UUID","workspaces":[
        {"ref":"workspace:1","id":"AIR-WORKSPACE-UUID","title":"Air","panes":[{"ref":"pane:1","id":"AIR-PANE-UUID","surfaces":[
          {"ref":"surface:1","id":"AIR-SURFACE-UUID","type":"terminal","title":"Agent One"},
          {"ref":"surface:browser","type":"browser","title":"Docs"}
        ]}]}
      ]},
      {"ref":"window:2","id":"MINI-WINDOW-UUID","workspaces":[
        {"ref":"workspace:6","id":"MINI-WORKSPACE-UUID","title":"SC (MacMini)","panes":[{"ref":"pane:9","id":"MINI-PANE-UUID","surfaces":[
          {"ref":"surface:55","id":"MINI-SURFACE-UUID","type":"terminal","title":"SC Restart"}
        ]}]}
      ]}
    ]}
    """

    let workspaces = try CMUXWorkspaceInventoryParser.parse(Data(json.utf8))

    #expect(workspaces.map(\.info) == [
        WorkspaceInfo(id: "workspace:1", persistentID: "AIR-WORKSPACE-UUID", title: "Air"),
        WorkspaceInfo(id: "workspace:6", persistentID: "MINI-WORKSPACE-UUID", title: "SC (MacMini)"),
    ])
    #expect(workspaces[0].lanes == [
        LaneSnapshot(
            id: "surface:1", persistentID: "AIR-SURFACE-UUID",
            title: "Agent One", state: .unknown,
            workspaceID: "workspace:1", workspacePersistentID: "AIR-WORKSPACE-UUID",
            workspaceTitle: "Air",
            navigationTarget: CMUXNavigationTarget(
                windowID: "AIR-WINDOW-UUID", windowRef: "window:1",
                workspaceID: "AIR-WORKSPACE-UUID", workspaceRef: "workspace:1",
                paneID: "AIR-PANE-UUID", paneRef: "pane:1",
                surfaceID: "AIR-SURFACE-UUID", surfaceRef: "surface:1"
            )
        ),
    ])
    #expect(workspaces[1].lanes == [
        LaneSnapshot(
            id: "surface:55", persistentID: "MINI-SURFACE-UUID",
            title: "SC Restart", state: .unknown,
            workspaceID: "workspace:6", workspacePersistentID: "MINI-WORKSPACE-UUID",
            workspaceTitle: "SC (MacMini)",
            navigationTarget: CMUXNavigationTarget(
                windowID: "MINI-WINDOW-UUID", windowRef: "window:2",
                workspaceID: "MINI-WORKSPACE-UUID", workspaceRef: "workspace:6",
                paneID: "MINI-PANE-UUID", paneRef: "pane:9",
                surfaceID: "MINI-SURFACE-UUID", surfaceRef: "surface:55"
            )
        ),
    ])
}
