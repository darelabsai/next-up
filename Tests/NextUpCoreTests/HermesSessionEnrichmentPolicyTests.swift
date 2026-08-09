import Testing
@testable import NextUpCore

@Test func inputRequiredLanesCannotInvokeHermesEnrichmentWork() {
    let inputLane = LaneSnapshot(
        id: "input",
        persistentID: "PRIVATE-SURFACE",
        title: "Private lane",
        state: .inputRequired,
        inputRequestKind: .approval,
        summary: "PRIVATE_SUMMARY_SENTINEL",
        matchingSnippet: "PRIVATE_SNIPPET_SENTINEL",
        workspacePersistentID: "PRIVATE-WORKSPACE",
        machine: "mac-mini"
    )
    var bindingCalls = 0
    var discoveryCalls = 0
    var bridgeCalls = 0
    var enrichmentCalls = 0

    for _ in HermesSessionEnrichmentPolicy.eligibleLanes(from: [inputLane]) {
        bindingCalls += 1
        discoveryCalls += 1
        bridgeCalls += 1
        enrichmentCalls += 1
    }

    #expect(bindingCalls == 0)
    #expect(discoveryCalls == 0)
    #expect(bridgeCalls == 0)
    #expect(enrichmentCalls == 0)
}

@Test func nonInputLanesRemainEligibleForHermesEnrichment() {
    let readyLane = LaneSnapshot(id: "ready", title: "Ready lane", state: .ready)

    let eligible = HermesSessionEnrichmentPolicy.eligibleLanes(from: [readyLane])

    #expect(eligible == [readyLane])
}
