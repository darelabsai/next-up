import Foundation
import Testing
@testable import NextUpCore

@Test func decodesPendingCompletionSavedBeforeWorkspaceMetadata() throws {
    let json = """
    {"previous":{"one":"ready"},"pending":[{"laneID":"one","title":"One","displayName":"One","summary":null,"completedAt":100,"lastAnnouncedAt":110}]}
    """

    let state = try JSONDecoder().decode(LaneMonitorState.self, from: Data(json.utf8))

    #expect(state.pending.first?.laneID == "one")
    #expect(state.pending.first?.workspaceID == nil)
    #expect(state.pending.first?.workspaceTitle == nil)
}

@Test func decodingLegacyPendingCompletionBoundsItsSummary() throws {
    let json = """
    {"previous":{"one":"ready"},"pending":[{"laneID":"one","title":"One","displayName":"One","summary":"The deployed watcher persisted a completion summary containing far too many words.","completedAt":100,"lastAnnouncedAt":110}]}
    """

    let state = try JSONDecoder().decode(LaneMonitorState.self, from: Data(json.utf8))

    #expect(state.pending.first?.summary?.split(whereSeparator: \.isWhitespace).count == 9)
}

@Test func inputRequiredClearsAnyStaleCompletion() {
    var state = LaneMonitorState()
    let busy = LaneSnapshot(id: "one", title: "Lane", state: .busy)
    let ready = LaneSnapshot(id: "one", title: "Lane", state: .ready)
    let input = LaneSnapshot(id: "one", title: "Lane", state: .inputRequired)

    state.observe([busy], now: Date(timeIntervalSince1970: 100))
    state.observe([ready], now: Date(timeIntervalSince1970: 110))
    #expect(state.pending.count == 1)
    state.observe([input], now: Date(timeIntervalSince1970: 120))

    #expect(state.pending.isEmpty)
}

@Test func firstPollBaselineDoesNotTurnPersistedBusyIntoCompletion() {
    var state = LaneMonitorState()
    let busy = LaneSnapshot(id: "one", title: "Lane", state: .busy)
    let ready = LaneSnapshot(id: "one", title: "Lane", state: .ready)
    state.observe([busy], now: Date(timeIntervalSince1970: 100))

    state.establishBaseline([ready])

    #expect(state.pending.isEmpty)
    #expect(state.previous["one"] == .ready)
}

@Test func laneQuarantinedBeforeFirstAuthoritativeSnapshotBaselinesWhenItLaterAppears() {
    var state = LaneMonitorState()
    var session = LaneObservationSession()
    let busy = LaneSnapshot(id: "hinted", title: "Lane", state: .busy)
    let ready = LaneSnapshot(id: "hinted", title: "Lane", state: .ready)
    state.observe([busy], now: Date(timeIntervalSince1970: 100))

    session.observe([], state: &state, now: Date(timeIntervalSince1970: 110))
    session.observe([ready], state: &state, now: Date(timeIntervalSince1970: 120))

    #expect(state.pending.isEmpty)
    #expect(state.previous["hinted"] == .ready)
}

@Test func perLaneBaselineStillAllowsLaterBusyToReadyCompletion() {
    var state = LaneMonitorState()
    var session = LaneObservationSession()
    let busy = LaneSnapshot(id: "one", title: "Lane", state: .busy)
    let ready = LaneSnapshot(id: "one", title: "Lane", state: .ready)

    session.observe([busy], state: &state, now: Date(timeIntervalSince1970: 100))
    session.observe([ready], state: &state, now: Date(timeIntervalSince1970: 110))

    #expect(state.pending.map(\.laneID) == ["one"])
}

@Test func busyToReadyCreatesPendingCompletion() {
    var state = LaneMonitorState()
    let busy = LaneSnapshot(id: "surface:57", title: "⏳ SC Restart · gpt-5.6-sol · ~", state: .busy)
    let ready = LaneSnapshot(id: "surface:57", title: "✓ SC Restart · gpt-5.6-sol · ~", state: .ready)

    state.observe([busy], now: Date(timeIntervalSince1970: 100))
    #expect(state.pending.isEmpty)
    state.observe([ready], now: Date(timeIntervalSince1970: 110))

    #expect(state.pending.map(\.laneID) == ["surface:57"])
    #expect(state.pending.first?.displayName == "SC Restart")
}

@Test func busyAgainMarksCompletionAsResponded() {
    var state = LaneMonitorState()
    let busy = LaneSnapshot(id: "surface:57", title: "⏳ SC Restart · gpt-5.6-sol · ~", state: .busy)
    let ready = LaneSnapshot(id: "surface:57", title: "✓ SC Restart · gpt-5.6-sol · ~", state: .ready)

    state.observe([busy], now: Date(timeIntervalSince1970: 100))
    state.observe([ready], now: Date(timeIntervalSince1970: 110))
    #expect(state.pending.count == 1)
    state.observe([busy], now: Date(timeIntervalSince1970: 120))

    #expect(state.pending.isEmpty)
}

@Test func forgettingUncheckedWorkspaceLanesClearsStateAndAlerts() {
    var state = LaneMonitorState()
    let busy = LaneSnapshot(id: "one", title: "One", state: .busy)
    let ready = LaneSnapshot(id: "one", title: "One", state: .ready)
    state.observe([busy], now: Date(timeIntervalSince1970: 100))
    state.observe([ready], now: Date(timeIntervalSince1970: 110))

    state.forget(laneIDs: ["one"])

    #expect(state.pending.isEmpty)
    #expect(state.previous["one"] == nil)
}

@Test func explicitAcknowledgeRemovesOnlySelectedCompletion() {
    var state = LaneMonitorState()
    let lanes = [
        LaneSnapshot(id: "one", title: "⏳ One · model", state: .busy),
        LaneSnapshot(id: "two", title: "⏳ Two · model", state: .busy),
    ]
    state.observe(lanes, now: Date(timeIntervalSince1970: 100))
    state.observe(lanes.map { LaneSnapshot(id: $0.id, title: $0.title.replacingOccurrences(of: "⏳", with: "✓"), state: .ready) }, now: Date(timeIntervalSince1970: 110))

    state.acknowledge(laneID: "one")

    #expect(state.pending.map(\.laneID) == ["two"])
}

@Test func completionCarriesPreparedSummaryAndWorkspace() {
    var state = LaneMonitorState()
    let busy = LaneSnapshot(
        id: "one", title: "One", state: .busy, summary: nil,
        workspaceID: "workspace:6", workspaceTitle: "SC"
    )
    let ready = LaneSnapshot(
        id: "one", title: "One", state: .ready,
        summary: "The report is ready for review.",
        workspaceID: "workspace:6", workspaceTitle: "SC"
    )

    state.observe([busy], now: Date(timeIntervalSince1970: 100))
    state.observe([ready], now: Date(timeIntervalSince1970: 110))

    #expect(state.pending.first?.summary == "The report is ready for review.")
    #expect(state.pending.first?.workspaceID == "workspace:6")
    #expect(state.pending.first?.workspaceTitle == "SC")
}

@Test func pendingCompletionBoundsPreparedSummaryAtTransition() {
    var state = LaneMonitorState()
    state.observe(
        [LaneSnapshot(id: "one", title: "One", state: .busy)],
        now: Date(timeIntervalSince1970: 100)
    )
    state.observe(
        [LaneSnapshot(
            id: "one", title: "One", state: .ready,
            summary: "The deployed watcher persisted a completion summary containing far too many words."
        )],
        now: Date(timeIntervalSince1970: 110)
    )

    #expect(state.pending.first?.summary?.split(whereSeparator: \.isWhitespace).count == 9)
}

@Test func announcementsStartImmediatelyThenRepeatOnIncreasingCadence() {
    var state = LaneMonitorState()
    let busy = LaneSnapshot(id: "one", title: "⏳ One · model", state: .busy)
    let ready = LaneSnapshot(id: "one", title: "✓ One · model", state: .ready)
    state.observe([busy], now: Date(timeIntervalSince1970: 100))
    state.observe([ready], now: Date(timeIntervalSince1970: 110))

    #expect(state.completionsDueForAnnouncement(at: Date(timeIntervalSince1970: 110)).map(\.laneID) == ["one"])
    state.markAnnounced(laneIDs: ["one"], at: Date(timeIntervalSince1970: 110))
    #expect(state.pending.first?.announcementCount == 1)
    #expect(state.completionsDueForAnnouncement(at: Date(timeIntervalSince1970: 409)).isEmpty)
    #expect(state.completionsDueForAnnouncement(at: Date(timeIntervalSince1970: 410)).map(\.laneID) == ["one"])
    state.markAnnounced(laneIDs: ["one"], at: Date(timeIntervalSince1970: 410))
    #expect(state.pending.first?.announcementCount == 2)
    #expect(state.completionsDueForAnnouncement(at: Date(timeIntervalSince1970: 1_009)).isEmpty)
    #expect(state.completionsDueForAnnouncement(at: Date(timeIntervalSince1970: 1_010)).map(\.laneID) == ["one"])
}

@Test func legacyPendingWithoutCountMigratesToOneWhenLastAnnouncementExists() throws {
    var state = LaneMonitorState()
    state.observe([LaneSnapshot(id: "one", title: "One", state: .busy)], now: .init(timeIntervalSince1970: 100))
    state.observe([LaneSnapshot(id: "one", title: "One", state: .ready)], now: .init(timeIntervalSince1970: 110))
    state.markAnnounced(laneIDs: ["one"], at: .init(timeIntervalSince1970: 110))
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    var pending = try #require(object["pending"] as? [[String: Any]])
    pending[0].removeValue(forKey: "announcementCount")
    object["pending"] = pending

    let migrated = try JSONDecoder().decode(
        LaneMonitorState.self,
        from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(migrated.pending.first?.announcementCount == 1)
    #expect(migrated.completionsDueForAnnouncement(at: .init(timeIntervalSince1970: 409)).isEmpty)
    #expect(migrated.completionsDueForAnnouncement(at: .init(timeIntervalSince1970: 410)).map(\.laneID) == ["one"])
}

@Test func malformedPersistedCountsNormalizeDeterministically() throws {
    let base = PendingCompletion(
        laneID: "one", title: "One", displayName: "One",
        completedAt: .init(timeIntervalSince1970: 100),
        lastAnnouncedAt: .init(timeIntervalSince1970: 110), announcementCount: 1
    )
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
    object["announcementCount"] = "not-an-integer"
    let malformed = try JSONDecoder().decode(
        PendingCompletion.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    #expect(malformed.announcementCount == 1)

    object["announcementCount"] = Int.max
    let oversized = try JSONDecoder().decode(
        PendingCompletion.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    #expect(oversized.announcementCount == ReminderSchedule.maximumAnnouncementCount)

    object["announcementCount"] = -4
    let negative = try JSONDecoder().decode(
        PendingCompletion.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    #expect(negative.announcementCount == 1)
}

@Test func displayNameRemovesWarningVariationSelectorAndStateOrnaments() {
    #expect(LaneMonitorState.displayName(from: "⚠️ ✓ ⏳ Build lane · gpt-5.6-sol") == "Build lane")
}

@Test func displayNameRemovesANSIControlsAndFormatScalarsButKeepsPunctuation() {
    let title = "\u{001B}[31m⚠\u{001B}[0m Bu\u{0007}ild?\u{200B} #1 · model"
    #expect(LaneMonitorState.displayName(from: title) == "Build? #1")
}

@Test func displayNameRemovesOSCAndDCSSequencesCompletely() {
    let title = "\u{001B}]0;secret window title\u{0007}\u{001B}Pprivate payload\u{001B}\\Build lane · model"
    #expect(LaneMonitorState.displayName(from: title) == "Build lane")
}

@Test func displayNamePreservesMeaningfulNonleadingEmojiVariation() {
    #expect(LaneMonitorState.displayName(from: "Project ✈️ · model") == "Project ✈️")
}

@Test func displayNameFallsBackWhenOnlyOrnamentsRemain() {
    #expect(LaneMonitorState.displayName(from: "⚠️ ✓ ⏳ · model") == "Agent lane")
}

@Test func snapshotKindsAffectEqualityAndSurviveSummaryUpdates() {
    let approval = LaneSnapshot(
        id: "one", title: "Lane", state: .inputRequired,
        inputRequestKind: .approval
    )
    let clarification = LaneSnapshot(
        id: "one", title: "Lane", state: .inputRequired,
        inputRequestKind: .clarification
    )

    #expect(approval != clarification)
    #expect(approval.withSummary("Updated").inputRequestKind == .approval)
}

@Test func nonInputSnapshotsNormalizeRequestKindsToNil() {
    for state in [LaneState.busy, .ready, .unknown] {
        let lane = LaneSnapshot(
            id: state.rawValue, title: "Lane", state: state,
            inputRequestKind: .approval
        )
        #expect(lane.inputRequestKind == nil)
        #expect(lane.withSummary("Updated").inputRequestKind == nil)
    }
}

@Test func pendingCompletionPersistsOpaqueNavigationRouteAcrossRestart() throws {
    let route = CMUXNavigationTarget(
        windowID: "window-uuid", workspaceID: "workspace-uuid",
        paneID: "pane-uuid", surfaceID: "surface-uuid", surfaceRef: "surface:9"
    )
    var state = LaneMonitorState()
    state.observe([
        LaneSnapshot(id: "surface:9", title: "Working", state: .busy, navigationTarget: route),
    ], now: Date(timeIntervalSince1970: 10))
    state.observe([
        LaneSnapshot(id: "surface:9", title: "Finished", state: .ready, navigationTarget: route),
    ], now: Date(timeIntervalSince1970: 20))
    state.markAnnounced(laneIDs: ["surface:9"], at: Date(timeIntervalSince1970: 21))

    let restored = try JSONDecoder().decode(
        LaneMonitorState.self,
        from: JSONEncoder().encode(state)
    )

    #expect(restored.pending.first?.navigationTarget == route)
    #expect(restored.pending.first?.announcementCount == 1)
}
