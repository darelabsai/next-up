import Testing
@testable import NextUpCore

@Test func workspaceSelectionDefaultsToEverythingIncludingFutureWorkspaces() {
    let selection = WorkspaceSelection()

    #expect(selection.isSelected("workspace:1"))
    #expect(selection.isSelected("workspace:new"))
}

@Test func togglingWorkspacePersistsOnlyExplicitExclusions() {
    var selection = WorkspaceSelection()

    selection.toggle("workspace:6")
    #expect(!selection.isSelected("workspace:6"))
    #expect(selection.isSelected("workspace:7"))

    selection.toggle("workspace:6")
    #expect(selection.isSelected("workspace:6"))
}

@Test func selectAllClearsEveryExclusion() {
    var selection = WorkspaceSelection(excludedWorkspaceIDs: ["workspace:1", "workspace:6"])
    selection.selectAll()

    #expect(selection.excludedWorkspaceIDs.isEmpty)
}
