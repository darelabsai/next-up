import Testing
@testable import NextUpCore

@Test func extractsLastSubstantiveLineBeforeReadyStatus() {
    let screen = """
    Earlier implementation details.
    All twelve tests pass and the updated watcher is installed.
    ─ ready │ gpt 5.6 sol │ ✓ 1m
    ❯
    """

    #expect(CompletionSummaryExtractor.extract(from: screen) == "All twelve tests pass and the updated watcher is…")
}

@Test func ignoresTerminalChromeAndPrompt() {
    let screen = """
    ╭─ Hermes ─╮
    Saved the readiness report to the project workspace. │
    ───────────────────────────────────────────────
    ❯
    [session:python3.11*
    """

    #expect(CompletionSummaryExtractor.extract(from: screen) == "Saved the readiness report to the project workspace.")
}

@Test func joinsShortWrappedEndingToItsPreviousLine() {
    let screen = """
    That is the only correction I would make. The main architectural misunderstanding has been
    resolved.
    ─ ready │ model
    ❯
    """

    #expect(CompletionSummaryExtractor.extract(from: screen) == "The main architectural misunderstanding has been resolved.")
}

@Test func ignoresPiModelStatusBar() {
    let screen = """
    💾 Self-improvement review: Updated the readiness reference.
    ⚕ gpt-5.6-sol │ 139K/372K │ ✓ 2m
    ───────────────────────────
    ❯
    [pi-session:python3.11*
    """

    #expect(CompletionSummaryExtractor.extract(from: screen) == "💾 Self-improvement review: Updated the readiness reference.")
}

@Test func summaryIsCappedToOneShortLine() {
    let long = String(repeating: "result ", count: 40) + "."
    let summary = CompletionSummaryExtractor.extract(from: "\(long)\n─ ready │ model\n❯")

    #expect(summary != nil)
    #expect(summary!.count <= 160)
    #expect(summary!.hasSuffix("…"))
}

@Test func visibleFallbackNeverExceedsNineWords() {
    let screen = "The deployed watcher persisted a completion summary containing far too many words.\n─ ready │ model\n❯"
    let summary = CompletionSummaryExtractor.extract(from: screen)

    #expect(summary != nil)
    #expect(summary!.split(whereSeparator: \.isWhitespace).count <= 9)
}

@Test func prefersFinalOutcomeAfterUnicodeEllipsis() {
    let screen = "Investigated several possible root causes with extensive debugging details… Implemented the fix and all tests pass.\n─ ready │ model\n❯"

    #expect(CompletionSummaryExtractor.extract(from: screen) == "Implemented the fix and all tests pass.")
}

@Test func ignoresEchoedUserPromptAboveReadyBar() {
    let screen = """
    The implementation is tested and ready for review.
    ↳ Can you check whether we are on track?
    ─ ready │ model
    ❯
    """

    #expect(CompletionSummaryExtractor.extract(from: screen) == "The implementation is tested and ready for review.")
}

@Test func ignoresTrailingSectionHeadingsAndLeadIns() {
    let screen = """
    It recommends Pi first while keeping the controller independent of Pi.
    Analysis coding inside the loop
    It correctly gives:
    ↳ Are we on track?
    ─ ready │ model
    ❯
    """

    #expect(CompletionSummaryExtractor.extract(from: screen) == "It recommends Pi first while keeping the controller independent…")
}

@Test func returnsNilWhenOnlyStatusChromeIsVisible() {
    #expect(CompletionSummaryExtractor.extract(from: "─ ready │ model\n❯") == nil)
}
