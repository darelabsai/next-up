import Testing
@testable import NextUpCore

private let completeFocus = CMUXActiveFocus(
    windowID: "window-uuid", windowRef: "window:1",
    workspaceID: "workspace-uuid", workspaceRef: "workspace:2",
    paneID: "pane-uuid", paneRef: "pane:3",
    surfaceID: "surface-uuid", surfaceRef: "surface:4"
)

private let completeTarget = CMUXNavigationTarget(
    windowID: "window-uuid", windowRef: "window:1",
    workspaceID: "workspace-uuid", workspaceRef: "workspace:2",
    paneID: "pane-uuid", paneRef: "pane:3",
    surfaceID: "surface-uuid", surfaceRef: "surface:4"
)

@Test func activeFocusExactlyMatchesAllFourPersistentIDs() {
    #expect(completeFocus.exactlyMatches(completeTarget))
}

@Test func activeFocusIgnoresRefsWhenPersistentIDsMatch() {
    let focus = CMUXActiveFocus(
        windowID: "window-uuid", windowRef: "changed-window-ref",
        workspaceID: "workspace-uuid", workspaceRef: "changed-workspace-ref",
        paneID: "pane-uuid", paneRef: "changed-pane-ref",
        surfaceID: "surface-uuid", surfaceRef: "changed-surface-ref"
    )

    #expect(focus.exactlyMatches(completeTarget))
}

@Test func activeFocusRejectsAnyConflictingPersistentID() {
    let conflicts = [
        CMUXActiveFocus(
            windowID: "other-window", workspaceID: "workspace-uuid",
            paneID: "pane-uuid", surfaceID: "surface-uuid"
        ),
        CMUXActiveFocus(
            windowID: "window-uuid", workspaceID: "other-workspace",
            paneID: "pane-uuid", surfaceID: "surface-uuid"
        ),
        CMUXActiveFocus(
            windowID: "window-uuid", workspaceID: "workspace-uuid",
            paneID: "other-pane", surfaceID: "surface-uuid"
        ),
        CMUXActiveFocus(
            windowID: "window-uuid", workspaceID: "workspace-uuid",
            paneID: "pane-uuid", surfaceID: "other-surface"
        ),
    ]

    for focus in conflicts {
        #expect(!focus.exactlyMatches(completeTarget))
    }
}

@Test func activeFocusRejectsMissingOrEmptyPersistentIDsOnEitherSide() {
    let incompleteFocuses = [
        CMUXActiveFocus(workspaceID: "workspace-uuid", paneID: "pane-uuid", surfaceID: "surface-uuid"),
        CMUXActiveFocus(windowID: "window-uuid", paneID: "pane-uuid", surfaceID: "surface-uuid"),
        CMUXActiveFocus(windowID: "window-uuid", workspaceID: "workspace-uuid", surfaceID: "surface-uuid"),
        CMUXActiveFocus(windowID: "window-uuid", workspaceID: "workspace-uuid", paneID: "pane-uuid"),
        CMUXActiveFocus(windowID: "", workspaceID: "workspace-uuid", paneID: "pane-uuid", surfaceID: "surface-uuid"),
    ]
    for focus in incompleteFocuses {
        #expect(!focus.exactlyMatches(completeTarget))
    }

    let incompleteTargets = [
        CMUXNavigationTarget(workspaceID: "workspace-uuid", paneID: "pane-uuid", surfaceID: "surface-uuid"),
        CMUXNavigationTarget(windowID: "window-uuid", paneID: "pane-uuid", surfaceID: "surface-uuid"),
        CMUXNavigationTarget(windowID: "window-uuid", workspaceID: "workspace-uuid", surfaceID: "surface-uuid"),
        CMUXNavigationTarget(windowID: "window-uuid", workspaceID: "workspace-uuid", paneID: "pane-uuid"),
    ]
    for target in incompleteTargets {
        #expect(!completeFocus.exactlyMatches(target))
    }
}
