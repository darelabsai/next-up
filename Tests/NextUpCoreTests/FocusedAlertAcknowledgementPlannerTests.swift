import Foundation
import Testing
@testable import NextUpCore

private let routeA = CMUXNavigationTarget(
    windowID: "window-a", windowRef: "window:1",
    workspaceID: "workspace-a", workspaceRef: "workspace:1",
    paneID: "pane-a", paneRef: "pane:1",
    surfaceID: "surface-a", surfaceRef: "surface:1"
)

private let focusA = CMUXActiveFocus(
    windowID: "window-a", windowRef: "window:1",
    workspaceID: "workspace-a", workspaceRef: "workspace:1",
    paneID: "pane-a", paneRef: "pane:1",
    surfaceID: "surface-a", surfaceRef: "surface:1"
)

private let routeBWithReusedRefs = CMUXNavigationTarget(
    windowID: "window-b", windowRef: "window:1",
    workspaceID: "workspace-b", workspaceRef: "workspace:1",
    paneID: "pane-b", paneRef: "pane:1",
    surfaceID: "surface-b", surfaceRef: "surface:1"
)

private let focusBWithReusedRefs = CMUXActiveFocus(
    windowID: "window-b", windowRef: "window:1",
    workspaceID: "workspace-b", workspaceRef: "workspace:1",
    paneID: "pane-b", paneRef: "pane:1",
    surfaceID: "surface-b", surfaceRef: "surface:1"
)

private func inventory(
    routes: [(laneID: String, target: CMUXNavigationTarget)],
    activeFocus: CMUXActiveFocus? = focusA
) -> CMUXWorkspaceInventorySnapshot {
    CMUXWorkspaceInventorySnapshot(
        records: [
            WorkspaceInventoryRecord(
                info: WorkspaceInfo(id: "workspace:1", persistentID: "workspace-a", title: "Workspace"),
                lanes: routes.map { laneID, target in
                    LaneSnapshot(
                        id: laneID,
                        title: laneID,
                        state: .unknown,
                        navigationTarget: target
                    )
                }
            ),
        ],
        activeFocus: activeFocus
    )
}

private func plan(
    _ alerts: [FocusAlertIdentity],
    topology: CMUXWorkspaceInventorySnapshot = inventory(routes: [("lane-a", routeA)]),
    frontmost: Bool = true,
    capturedAt: Date? = Date(timeIntervalSince1970: 100),
    reconciledAt: Date = Date(timeIntervalSince1970: 102)
) -> Set<String> {
    FocusedAlertAcknowledgementPlanner.laneIDsToAcknowledge(
        eligibleAlerts: alerts,
        topology: topology,
        isCMUXFrontmost: frontmost,
        capturedAt: capturedAt,
        reconciledAt: reconciledAt
    )
}

@Test func acknowledgesCompletionWhoseCapturedRouteIsExactlyFocusedAndPresent() {
    #expect(plan([
        FocusAlertIdentity(kind: .completion, laneID: "lane-a", navigationTarget: routeA),
    ]) == ["lane-a"])
}

@Test func acknowledgesInputRequiredWhoseCapturedRouteIsExactlyFocusedAndPresent() {
    #expect(plan([
        FocusAlertIdentity(kind: .inputRequired, laneID: "lane-a", navigationTarget: routeA),
    ]) == ["lane-a"])
}

@Test func mixedAlertKindsReturnOnlyFocusedLaneIDsAndDeduplicateSharedLane() {
    let alerts = [
        FocusAlertIdentity(kind: .completion, laneID: "shared", navigationTarget: routeA),
        FocusAlertIdentity(kind: .inputRequired, laneID: "shared", navigationTarget: routeA),
        FocusAlertIdentity(kind: .completion, laneID: "other", navigationTarget: routeBWithReusedRefs),
    ]

    #expect(plan(alerts) == ["shared"])
}

@Test func rejectsExactFocusWhenCMUXIsNotFrontmost() {
    #expect(plan([
        FocusAlertIdentity(kind: .completion, laneID: "lane-a", navigationTarget: routeA),
    ], frontmost: false).isEmpty)
}

@Test func rejectsAbsentActiveFocus() {
    #expect(plan([
        FocusAlertIdentity(kind: .completion, laneID: "lane-a", navigationTarget: routeA),
    ], topology: inventory(routes: [("lane-a", routeA)], activeFocus: nil)).isEmpty)
}

@Test func rejectsPartialActiveFocusIncludingMissingReference() {
    let partialFocuses = [
        CMUXActiveFocus(
            windowRef: "window:1",
            workspaceID: "workspace-a", workspaceRef: "workspace:1",
            paneID: "pane-a", paneRef: "pane:1",
            surfaceID: "surface-a", surfaceRef: "surface:1"
        ),
        CMUXActiveFocus(
            windowID: "window-a",
            workspaceID: "workspace-a", workspaceRef: "workspace:1",
            paneID: "pane-a", paneRef: "pane:1",
            surfaceID: "surface-a", surfaceRef: "surface:1"
        ),
    ]

    for partialFocus in partialFocuses {
        #expect(plan([
            FocusAlertIdentity(kind: .completion, laneID: "lane-a", navigationTarget: routeA),
        ], topology: inventory(routes: [("lane-a", routeA)], activeFocus: partialFocus)).isEmpty)
    }
}

@Test func rejectsAmbiguousInventoryContainingFocusedRouteMoreThanOnce() {
    #expect(plan([
        FocusAlertIdentity(kind: .completion, laneID: "lane-a", navigationTarget: routeA),
    ], topology: inventory(routes: [("lane-a", routeA), ("duplicate", routeA)])).isEmpty)
}

@Test func rejectsMissingOrPartialAlertRoute() {
    let partialRoutes = [
        CMUXNavigationTarget(
            windowRef: "window:1",
            workspaceID: "workspace-a", workspaceRef: "workspace:1",
            paneID: "pane-a", paneRef: "pane:1",
            surfaceID: "surface-a", surfaceRef: "surface:1"
        ),
        CMUXNavigationTarget(
            windowID: "",
            workspaceID: "workspace-a", workspaceRef: "workspace:1",
            paneID: "pane-a", paneRef: "pane:1",
            surfaceID: "surface-a", surfaceRef: "surface:1"
        ),
    ]

    for route in partialRoutes {
        #expect(plan([
            FocusAlertIdentity(kind: .inputRequired, laneID: "lane-a", navigationTarget: route),
        ]).isEmpty)
    }
}

@Test func rejectsAlertWithoutLaneID() {
    #expect(plan([
        FocusAlertIdentity(kind: .inputRequired, laneID: "", navigationTarget: routeA),
    ]).isEmpty)
}

@Test func rejectsAnyDifferingPersistentID() {
    let mismatches = [
        CMUXNavigationTarget(
            windowID: "other", windowRef: "window:1",
            workspaceID: "workspace-a", workspaceRef: "workspace:1",
            paneID: "pane-a", paneRef: "pane:1",
            surfaceID: "surface-a", surfaceRef: "surface:1"
        ),
        CMUXNavigationTarget(
            windowID: "window-a", windowRef: "window:1",
            workspaceID: "other", workspaceRef: "workspace:1",
            paneID: "pane-a", paneRef: "pane:1",
            surfaceID: "surface-a", surfaceRef: "surface:1"
        ),
        CMUXNavigationTarget(
            windowID: "window-a", windowRef: "window:1",
            workspaceID: "workspace-a", workspaceRef: "workspace:1",
            paneID: "other", paneRef: "pane:1",
            surfaceID: "surface-a", surfaceRef: "surface:1"
        ),
        CMUXNavigationTarget(
            windowID: "window-a", windowRef: "window:1",
            workspaceID: "workspace-a", workspaceRef: "workspace:1",
            paneID: "pane-a", paneRef: "pane:1",
            surfaceID: "other", surfaceRef: "surface:1"
        ),
    ]

    for route in mismatches {
        #expect(plan([
            FocusAlertIdentity(kind: .completion, laneID: "lane-a", navigationTarget: route),
        ]).isEmpty)
    }
}

@Test func staleReferencesStillMatchWhenAllPersistentIDsMatch() {
    let staleCapturedRoute = CMUXNavigationTarget(
        windowID: "window-a", windowRef: "stale-window",
        workspaceID: "workspace-a", workspaceRef: "stale-workspace",
        paneID: "pane-a", paneRef: "stale-pane",
        surfaceID: "surface-a", surfaceRef: "stale-surface"
    )

    #expect(plan([
        FocusAlertIdentity(kind: .inputRequired, laneID: "lane-a", navigationTarget: staleCapturedRoute),
    ]) == ["lane-a"])
}

@Test func capturedRouteWithPersistentIDsAndNoRefsStillMatches() {
    let capturedRoute = CMUXNavigationTarget(
        windowID: "window-a",
        workspaceID: "workspace-a",
        paneID: "pane-a",
        surfaceID: "surface-a"
    )

    #expect(plan([
        FocusAlertIdentity(kind: .completion, laneID: "lane-a", navigationTarget: capturedRoute),
    ]) == ["lane-a"])
}

@Test func focusSampleFreshnessIsInclusiveAndFailsClosed() {
    let alert = FocusAlertIdentity(kind: .completion, laneID: "lane-a", navigationTarget: routeA)
    let captured = Date(timeIntervalSince1970: 100)

    #expect(plan([alert], capturedAt: captured, reconciledAt: captured.addingTimeInterval(2)) == ["lane-a"])
    #expect(plan([alert], capturedAt: captured, reconciledAt: captured.addingTimeInterval(2.001)).isEmpty)
    #expect(plan([alert], capturedAt: nil, reconciledAt: captured).isEmpty)
    #expect(plan([alert], capturedAt: captured, reconciledAt: captured.addingTimeInterval(-0.001)).isEmpty)
}

@Test func reusedReferencesCannotMakeRouteAAcknowledgeWhileRouteBIsFocused() {
    let topology = inventory(
        routes: [("lane-b", routeBWithReusedRefs)],
        activeFocus: focusBWithReusedRefs
    )

    #expect(plan([
        FocusAlertIdentity(kind: .completion, laneID: "lane-a", navigationTarget: routeA),
    ], topology: topology).isEmpty)
}

@Test func rejectsFocusThatIsAbsentFromSameInventorySnapshot() {
    #expect(plan([
        FocusAlertIdentity(kind: .completion, laneID: "lane-a", navigationTarget: routeA),
    ], topology: inventory(routes: [("lane-b", routeBWithReusedRefs)])).isEmpty)
}

@Test func ignoresManyPaneSelectedSurfacesAndUsesOnlySingularRootFocus() throws {
    let json = """
    {"active":{
      "window_ref":"window:1","window_id":"window-a",
      "workspace_ref":"workspace:1","workspace_id":"workspace-a",
      "pane_ref":"pane:2","pane_id":"pane-a",
      "surface_ref":"surface:2","surface_id":"surface-a"
    },"windows":[{"ref":"window:1","id":"window-a","workspaces":[
      {"ref":"workspace:1","id":"workspace-a","title":"Workspace","panes":[
        {"ref":"pane:1","id":"pane-other","selected_surface_ref":"surface:1","selected_surface_id":"surface-other","surfaces":[
          {"ref":"surface:1","id":"surface-other","type":"terminal","title":"Other","selected":true}
        ]},
        {"ref":"pane:2","id":"pane-a","selected_surface_ref":"surface:2","selected_surface_id":"surface-a","surfaces":[
          {"ref":"surface:2","id":"surface-a","type":"terminal","title":"Focused","selected":true}
        ]}
      ]}
    ]}]}
    """
    let topology = try CMUXWorkspaceInventoryParser.parseSnapshot(Data(json.utf8))
    let capturedFocusedRoute = CMUXNavigationTarget(
        windowID: "window-a", windowRef: "captured-window-ref",
        workspaceID: "workspace-a", workspaceRef: "captured-workspace-ref",
        paneID: "pane-a", paneRef: "captured-pane-ref",
        surfaceID: "surface-a", surfaceRef: "captured-surface-ref"
    )

    #expect(plan([
        FocusAlertIdentity(kind: .completion, laneID: "focused", navigationTarget: capturedFocusedRoute),
        FocusAlertIdentity(
            kind: .inputRequired,
            laneID: "other",
            navigationTarget: CMUXNavigationTarget(
                windowID: "window-a", windowRef: "window:1",
                workspaceID: "workspace-a", workspaceRef: "workspace:1",
                paneID: "pane-other", paneRef: "pane:1",
                surfaceID: "surface-other", surfaceRef: "surface:1"
            )
        ),
    ], topology: topology) == ["focused"])
}
