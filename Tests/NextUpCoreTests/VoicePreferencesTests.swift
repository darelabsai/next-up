import Foundation
import Testing
@testable import NextUpCore

@Test func voiceModeOffSuppressesCompletionAndInputSpeech() {
    let completion = PendingCompletion(
        laneID: "one", title: "One", displayName: "One",
        summary: "Tests pass.", completedAt: Date(timeIntervalSince1970: 100)
    )
    #expect(VoiceAnnouncementFormatter.completions([completion], mode: .off, at: .distantFuture) == nil)
    #expect(VoiceAnnouncementFormatter.inputRequired(laneNames: ["One"], mode: .off) == nil)
}

@Test func titleOnlyVoiceOmitsSummary() {
    let completion = PendingCompletion(
        laneID: "one", title: "One", displayName: "One",
        summary: "Tests pass.", completedAt: Date(timeIntervalSince1970: 100)
    )
    let spoken = VoiceAnnouncementFormatter.completions(
        [completion], mode: .titleOnly, at: Date(timeIntervalSince1970: 100)
    )
    #expect(spoken?.contains("One") == true)
    #expect(spoken?.contains("Tests pass") == false)
}

@Test func titleAndSummaryVoiceIncludesBoth() {
    let completion = PendingCompletion(
        laneID: "one", title: "One", displayName: "One",
        summary: "Tests pass.", completedAt: Date(timeIntervalSince1970: 100)
    )
    let spoken = VoiceAnnouncementFormatter.completions(
        [completion], mode: .titleAndSummary, at: Date(timeIntervalSince1970: 100)
    )
    #expect(spoken?.contains("One") == true)
    #expect(spoken?.contains("Tests pass") == true)
}

@Test func legacyInputFormatterUsesFriendlyResponseFallback() {
    #expect(
        VoiceAnnouncementFormatter.inputRequired(
            laneNames: ["One"], mode: .titleOnly
        ) == "Heads up. One is waiting for your response."
    )
    #expect(
        VoiceAnnouncementFormatter.inputRequired(
            laneNames: ["One"], mode: .off
        ) == nil
    )
}
