import Foundation
import Testing
@testable import NextUpCore

@Test func navigationTargetRoundTripsThroughOpaqueUserInfo() throws {
    let target = CMUXNavigationTarget(
        windowID: "window-uuid", windowRef: "window:1",
        workspaceID: "workspace-uuid", workspaceRef: "workspace:2",
        paneID: "pane-uuid", paneRef: "pane:3",
        surfaceID: "surface-uuid", surfaceRef: "surface:4"
    )

    let userInfo = target.userInfo

    #expect(CMUXNavigationTarget(userInfo: userInfo) == target)
    #expect(Set(userInfo.keys) == [
        "cmuxWindowID", "cmuxWindowRef", "cmuxWorkspaceID", "cmuxWorkspaceRef",
        "cmuxPaneID", "cmuxPaneRef", "cmuxSurfaceID", "cmuxSurfaceRef",
    ])
    #expect(!userInfo.values.contains("SENTINEL PRIVATE TITLE"))
}

@Test func navigationTargetOmitsMissingValuesAndRejectsAnEmptyEnvelope() {
    let target = CMUXNavigationTarget(
        windowID: "window-uuid", workspaceID: "workspace-uuid",
        surfaceID: "surface-uuid"
    )

    #expect(target.userInfo == [
        "cmuxWindowID": "window-uuid",
        "cmuxWorkspaceID": "workspace-uuid",
        "cmuxSurfaceID": "surface-uuid",
    ])
    #expect(CMUXNavigationTarget(userInfo: [:]) == nil)
    #expect(CMUXNavigationTarget(userInfo: ["cmuxSurfaceID": ""]) == nil)
}

@Test func navigationTargetCodableRoundTripPreservesEveryIdentifier() throws {
    let target = CMUXNavigationTarget(
        windowID: "window-uuid", windowRef: "window:1",
        workspaceID: "workspace-uuid", workspaceRef: "workspace:2",
        paneID: "pane-uuid", paneRef: "pane:3",
        surfaceID: "surface-uuid", surfaceRef: "surface:4"
    )

    let data = try JSONEncoder().encode(target)

    #expect(try JSONDecoder().decode(CMUXNavigationTarget.self, from: data) == target)
}

@Test func navigationTargetCodableRejectsAnEmptyOpaqueEnvelope() {
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(CMUXNavigationTarget.self, from: Data("{}".utf8))
    }
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(
            CMUXNavigationTarget.self,
            from: Data(#"{"surfaceID":""}"#.utf8)
        )
    }
}
