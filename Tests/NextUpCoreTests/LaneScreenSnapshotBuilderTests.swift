import Testing
@testable import NextUpCore

@Test func inputRequiredScreenSkipsCompletionExtraction() {
    var extractedScreens: [String] = []
    let sensitiveScreen = """
    ╔════════════════════════════════════════════════════════════╗
    ║ ⚠ approval required · run command                         ║
    ║ PRIVATE_PROMPT_SENTINEL                                    ║
    ║ 1. Allow once                                              ║
    ║ 2. Deny                                                    ║
    ║ ↑/↓ select · Enter confirm · 1-2 quick pick · Esc/Ctrl+C deny ║
    ╚════════════════════════════════════════════════════════════╝
    """

    let snapshot = LaneScreenSnapshotBuilder.build(
        id: "surface:1",
        persistentID: "SURFACE-UUID",
        title: "⚠ Private lane",
        workspaceID: "workspace:1",
        workspacePersistentID: "WORKSPACE-UUID",
        workspaceTitle: "Private workspace",
        machine: "mac-air",
        hermesProfile: "default",
        screen: sensitiveScreen,
        extractSummary: { screen in
            extractedScreens.append(screen)
            return "LEAKED_SUMMARY"
        }
    )

    #expect(snapshot.state == .inputRequired)
    #expect(snapshot.inputRequestKind == .approval)
    #expect(snapshot.summary == nil)
    #expect(snapshot.matchingSnippet == nil)
    #expect(extractedScreens.isEmpty)
}

@Test func inputRequiredSnapshotInitializerClearsCompletionEvidence() {
    let snapshot = LaneSnapshot(
        id: "surface:1",
        title: "Private lane",
        state: .inputRequired,
        inputRequestKind: .clarification,
        summary: "PRIVATE_SUMMARY_SENTINEL",
        matchingSnippet: "PRIVATE_SNIPPET_SENTINEL"
    )

    #expect(snapshot.summary == nil)
    #expect(snapshot.matchingSnippet == nil)
}

@Test func nonInputScreenRetainsExistingCompletionExtractionBehavior() {
    var extractionCalls = 0
    let snapshot = LaneScreenSnapshotBuilder.build(
        id: "surface:2",
        title: "Completed lane",
        screen: "The verified deployment completed successfully.",
        extractSummary: { _ in
            extractionCalls += 1
            return "The verified deployment completed successfully."
        }
    )

    #expect(extractionCalls == 1)
    #expect(snapshot.summary == "The verified deployment completed successfully.")
    #expect(snapshot.matchingSnippet == snapshot.summary)
}

@Test func inputRequiredSnapshotRejectsReplacementSummary() {
    let snapshot = LaneSnapshot(
        id: "surface:1",
        title: "Private lane",
        state: .inputRequired,
        inputRequestKind: .response,
        summary: "PRIVATE_SUMMARY_SENTINEL",
        matchingSnippet: "PRIVATE_SNIPPET_SENTINEL"
    )

    let updated = snapshot.withSummary("PRIVATE_REPLACEMENT_SENTINEL")

    #expect(updated.summary == nil)
    #expect(updated.matchingSnippet == nil)
}
