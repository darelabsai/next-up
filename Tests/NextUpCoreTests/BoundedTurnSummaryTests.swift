import Testing
@testable import NextUpCore

@Test func turnSummaryUsesFinalAssistantOutcomeAndStaysUnderTenWords() {
    let turn = HermesFinalTurn(
        userText: "Please fix the approval state classifier.",
        assistantText: "I investigated the issue. Implemented urgent approval alerts and fixed false completions; all tests pass.",
        toolNames: ["patch", "terminal"], lastMessageID: 10
    )

    let summary = BoundedTurnSummary.summarize(turn)

    #expect(summary == "Implemented urgent approval alerts and fixed false completions; all…")
    #expect((summary?.split(whereSeparator: \.isWhitespace).count ?? 0) <= 9)
}

@Test func turnSummaryRejectsEmptyAssistantOutput() {
    let turn = HermesFinalTurn(userText: "Do it", assistantText: "   ", toolNames: [], lastMessageID: 1)
    #expect(BoundedTurnSummary.summarize(turn) == nil)
}
