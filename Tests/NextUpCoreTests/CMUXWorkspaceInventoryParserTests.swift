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

@Test func parsesOnlyTheSingularRootActivePathAlongsideAllSelectedSurfaces() throws {
    let json = """
    {"active":{
      "window_ref":"window:1","window_id":"WINDOW-UUID",
      "workspace_ref":"workspace:1","workspace_id":"WORKSPACE-UUID",
      "pane_ref":"pane:2","pane_id":"PANE-2-UUID",
      "surface_ref":"surface:2","surface_id":"SURFACE-2-UUID"
    },"windows":[
      {"ref":"window:1","id":"WINDOW-UUID","workspaces":[
        {"ref":"workspace:1","id":"WORKSPACE-UUID","title":"Workspace","panes":[
          {"ref":"pane:1","id":"PANE-1-UUID","selected_surface_ref":"surface:1","selected_surface_id":"SURFACE-1-UUID","surfaces":[
            {"ref":"surface:1","id":"SURFACE-1-UUID","type":"terminal","title":"One","selected":true}
          ]},
          {"ref":"pane:2","id":"PANE-2-UUID","selected_surface_ref":"surface:2","selected_surface_id":"SURFACE-2-UUID","surfaces":[
            {"ref":"surface:2","id":"SURFACE-2-UUID","type":"terminal","title":"Two","selected":true}
          ]}
        ]}
      ]}
    ]}
    """

    let snapshot = try CMUXWorkspaceInventoryParser.parseSnapshot(Data(json.utf8))

    #expect(snapshot.records.count == 1)
    #expect(snapshot.records[0].lanes.map(\.id) == ["surface:1", "surface:2"])
    #expect(snapshot.activeFocus == CMUXActiveFocus(
        windowID: "WINDOW-UUID", windowRef: "window:1",
        workspaceID: "WORKSPACE-UUID", workspaceRef: "workspace:1",
        paneID: "PANE-2-UUID", paneRef: "pane:2",
        surfaceID: "SURFACE-2-UUID", surfaceRef: "surface:2"
    ))
    #expect(try CMUXWorkspaceInventoryParser.parse(Data(json.utf8)) == snapshot.records)
}

@Test(arguments: [
    "missing",
    "\"active\":\"not-an-object\"",
    "\"active\":{\"window_ref\":\"window:1\",\"window_id\":\"WINDOW-UUID\",\"workspace_ref\":\"workspace:1\",\"workspace_id\":\"WORKSPACE-UUID\",\"pane_ref\":\"pane:1\",\"pane_id\":\"PANE-UUID\",\"surface_ref\":\"surface:1\"}",
    "\"active\":[{\"window_ref\":\"window:1\"},{\"window_ref\":\"window:2\"}]",
])
func invalidRootActiveFocusFailsClosedWithoutDiscardingInventory(activeMember: String) throws {
    let activePrefix = activeMember == "missing" ? "" : "\(activeMember),"
    let json = """
    {\(activePrefix)"windows":[{"ref":"window:1","id":"WINDOW-UUID","workspaces":[
      {"ref":"workspace:1","id":"WORKSPACE-UUID","title":"Workspace","panes":[
        {"ref":"pane:1","id":"PANE-UUID","surfaces":[
          {"ref":"surface:1","id":"SURFACE-UUID","type":"terminal","title":"Lane"}
        ]}
      ]}
    ]}]}
    """

    let snapshot = try CMUXWorkspaceInventoryParser.parseSnapshot(Data(json.utf8))

    #expect(snapshot.activeFocus == nil)
    #expect(snapshot.records.count == 1)
    #expect(snapshot.records[0].lanes.map(\.id) == ["surface:1"])
}
