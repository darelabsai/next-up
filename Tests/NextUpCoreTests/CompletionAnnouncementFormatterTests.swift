import Foundation
import Testing
@testable import NextUpCore

private func completion(
    id: String = "one",
    name: String = "One",
    summary: String? = "The report is ready for review.",
    workspace: String = "SC",
    completedAt: TimeInterval = 100,
    lastAnnouncedAt: TimeInterval? = nil
) -> PendingCompletion {
    PendingCompletion(
        laneID: id,
        title: name,
        displayName: name,
        summary: summary,
        workspaceID: "workspace:\(workspace)",
        workspaceTitle: workspace,
        completedAt: Date(timeIntervalSince1970: completedAt),
        lastAnnouncedAt: lastAnnouncedAt.map(Date.init(timeIntervalSince1970:))
    )
}

@Test func firstAnnouncementFlowsWithoutSummaryLabel() {
    let spoken = CompletionAnnouncementFormatter.spoken(
        [completion()],
        at: Date(timeIntervalSince1970: 100)
    )

    #expect(spoken == "One finished — The report is ready for review.")
    #expect(!spoken.contains("Summary:"))
}

@Test func repeatAnnouncementRoundsIdleMinutesUp() {
    let spoken = CompletionAnnouncementFormatter.spoken(
        [completion(lastAnnouncedAt: 110)],
        at: Date(timeIntervalSince1970: 221)
    )

    #expect(spoken == "One finished about 3 minutes ago — The report is ready for review.")
}

@Test func repeatAnnouncementUsesSingularMinuteNaturally() {
    let spoken = CompletionAnnouncementFormatter.spoken(
        [completion(completedAt: 100, lastAnnouncedAt: 110)],
        at: Date(timeIntervalSince1970: 160)
    )

    #expect(spoken == "One finished about 1 minute ago — The report is ready for review.")
}

@Test func repeatAnnouncementUsesNaturalHourAndMinuteWording() {
    let exactHour = CompletionAnnouncementFormatter.notificationBody(
        completion(summary: nil, completedAt: 100, lastAnnouncedAt: 110),
        at: Date(timeIntervalSince1970: 3_700)
    )
    let hourAndMinutes = CompletionAnnouncementFormatter.notificationBody(
        completion(summary: nil, completedAt: 100, lastAnnouncedAt: 110),
        at: Date(timeIntervalSince1970: 4_480)
    )
    let pluralHoursAndMinute = CompletionAnnouncementFormatter.notificationBody(
        completion(summary: nil, completedAt: 100, lastAnnouncedAt: 110),
        at: Date(timeIntervalSince1970: 7_360)
    )

    #expect(exactHour == "Finished about an hour ago.")
    #expect(hourAndMinutes == "Finished about an hour and 13 minutes ago.")
    #expect(pluralHoursAndMinute == "Finished about 2 hours and 1 minute ago.")
}

@Test func firstAnnouncementsAreGroupedByWorkspace() {
    let completions = [
        completion(id: "one", name: "Clara", summary: "Validated readiness."),
        completion(id: "two", name: "Glen", summary: "Fixed routing."),
    ]

    let spoken = CompletionAnnouncementFormatter.spoken(
        completions,
        at: Date(timeIntervalSince1970: 100)
    )

    #expect(spoken == "Two SC lanes finished: Clara — Validated readiness; Glen — Fixed routing.")
}

@Test func repeatAnnouncementsKeepEachLanesRoundedAge() {
    let completions = [
        completion(id: "one", name: "Clara", summary: "Validated readiness.", completedAt: 100, lastAnnouncedAt: 110),
        completion(id: "two", name: "Glen", summary: "Fixed routing.", completedAt: 40, lastAnnouncedAt: 110),
    ]

    let spoken = CompletionAnnouncementFormatter.spoken(
        completions,
        at: Date(timeIntervalSince1970: 221)
    )

    #expect(spoken == "Two SC lanes are waiting. Clara finished about 3 minutes ago — Validated readiness. Glen finished about 4 minutes ago — Fixed routing.")
}

@Test func firstAnnouncementFallsBackCleanlyWithoutSummary() {
    let spoken = CompletionAnnouncementFormatter.spoken(
        [completion(summary: nil)],
        at: Date(timeIntervalSince1970: 100)
    )

    #expect(spoken == "One finished.")
}
