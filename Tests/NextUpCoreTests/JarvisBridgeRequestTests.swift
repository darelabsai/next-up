import Testing
@testable import NextUpCore

@Test func discoveryRequestKeepsVisibleContentOutOfArguments() throws {
    let lane = LaneSnapshot(
        id: "surface:1", persistentID: "S", title: "✓ Duplicate · gpt · ~",
        state: .ready, summary: "short completion",
        matchingSnippet: "distinctive visible result",
        workspacePersistentID: "W", machine: "mac-mini"
    )

    let request = try JarvisBridgeRequest.discovery(
        lane: lane, registryPath: "/tmp/machines.json"
    )

    #expect(request.arguments.contains("find"))
    #expect(request.arguments.contains("--snippet-stdin"))
    #expect(!request.arguments.contains("distinctive visible result"))
    #expect(request.standardInput == "distinctive visible result")
    #expect(request.arguments.contains("mac-mini"))
}

@Test func discoveryRefusesTitleOnlyBinding() {
    let lane = LaneSnapshot(
        id: "surface:1", persistentID: "S", title: "Duplicate",
        state: .ready, workspacePersistentID: "W"
    )

    #expect(throws: JarvisBridgeRequestError.missingMatchingSnippet) {
        try JarvisBridgeRequest.discovery(lane: lane, registryPath: "/tmp/machines.json")
    }
}

@Test func exactTurnRequestUsesCachedSessionAndNoSnippet() {
    let binding = HermesSessionBinding(
        surfacePersistentID: "S", workspacePersistentID: "W",
        machine: "mac-air", profile: "default", sessionID: "session-123",
        matchMethod: "title+snippet", resolvedAt: .distantPast
    )

    let request = JarvisBridgeRequest.exactTurn(
        binding: binding, registryPath: "/tmp/machines.json"
    )

    #expect(request.arguments.contains("get"))
    #expect(request.arguments.contains("session-123"))
    #expect(!request.arguments.contains("--snippet-stdin"))
    #expect(request.standardInput == nil)
}
