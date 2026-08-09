import Testing
@testable import NextUpCore

private func inputLane(
    id: String,
    title: String,
    kind: InputRequestKind?,
    navigationTarget: CMUXNavigationTarget? = nil
) -> LaneSnapshot {
    LaneSnapshot(
        id: id,
        title: title,
        state: .inputRequired,
        inputRequestKind: kind,
        navigationTarget: navigationTarget
    )
}

@Test func approvalPlanUsesFriendlySanitizedExactPresentation() {
    let lane = inputLane(
        id: "build", title: "⚠️ Build lane · gpt", kind: .approval,
        navigationTarget: CMUXNavigationTarget(
            windowID: "WINDOW", workspaceID: "WORKSPACE", surfaceID: "SURFACE"
        )
    )

    let plan = InputAttentionAnnouncementPlanner.plan(
        lanes: [lane], dueLaneIDs: ["build"],
        voiceMode: .titleAndSummary, completionsAreDue: false
    )

    #expect(plan.spoken == "Heads up. Build lane needs your approval.")
    #expect(plan.notifications == [InputRequestNotificationPresentation(
        laneID: "build",
        identifier: "next-up-build",
        userInfo: [
            "laneID": "build", "kind": "input-required",
            "cmuxWindowID": "WINDOW", "cmuxWorkspaceID": "WORKSPACE",
            "cmuxSurfaceID": "SURFACE",
        ],
        title: "Build lane needs attention",
        body: "Approval required in Hermes."
    )])
    #expect(plan.shouldSpeakCompletions == false)
}

@Test func mixedPlanPreservesSnapshotOrderAndKindAlignment() {
    let lanes = [
        inputLane(id: "build", title: "Build lane", kind: .approval),
        inputLane(id: "research", title: "Research lane", kind: .clarification),
        inputLane(id: "deploy", title: "Deploy lane", kind: .response),
        inputLane(id: "not-due", title: "Not due", kind: .approval),
    ]

    let plan = InputAttentionAnnouncementPlanner.plan(
        lanes: lanes,
        dueLaneIDs: ["research", "deploy", "build"],
        voiceMode: .titleOnly,
        completionsAreDue: true
    )

    #expect(plan.spoken == "Heads up. Build lane needs your approval. Research lane has a question for you. Deploy lane is waiting for your response.")
    #expect(plan.notifications.map(\.laneID) == ["build", "research", "deploy"])
    #expect(plan.notifications.map(\.identifier) == ["next-up-build", "next-up-research", "next-up-deploy"])
    #expect(plan.notifications.map(\.body) == [
        "Approval required in Hermes.",
        "Question waiting in Hermes.",
        "Response required in Hermes.",
    ])
    #expect(plan.notifications.map(\.userInfo) == [
        ["laneID": "build", "kind": "input-required"],
        ["laneID": "research", "kind": "input-required"],
        ["laneID": "deploy", "kind": "input-required"],
    ])
    #expect(plan.shouldSpeakCompletions == false)
}

@Test func missingKindFallsBackToResponsePresentation() {
    let lane = inputLane(id: "deploy", title: "⚠ Deploy · gpt", kind: nil)

    let plan = InputAttentionAnnouncementPlanner.plan(
        lanes: [lane], dueLaneIDs: ["deploy"],
        voiceMode: .titleAndSummary, completionsAreDue: false
    )

    #expect(plan.spoken == "Heads up. Deploy is waiting for your response.")
    #expect(plan.notifications.first?.title == "Deploy needs attention")
    #expect(plan.notifications.first?.body == "Response required in Hermes.")
}

@Test func voiceOffKeepsNotificationsButSuppressesSpeech() {
    let lane = inputLane(id: "research", title: "Research", kind: .clarification)

    let plan = InputAttentionAnnouncementPlanner.plan(
        lanes: [lane], dueLaneIDs: ["research"],
        voiceMode: .off, completionsAreDue: true
    )

    #expect(plan.spoken == nil)
    #expect(plan.notifications.count == 1)
    #expect(plan.shouldSpeakCompletions == false)
}

@Test func titleModesUseIdenticalPrivateInputSpeech() {
    let lane = inputLane(id: "research", title: "Research", kind: .clarification)
    let titleOnly = InputAttentionAnnouncementPlanner.plan(
        lanes: [lane], dueLaneIDs: ["research"],
        voiceMode: .titleOnly, completionsAreDue: false
    )
    let withSummary = InputAttentionAnnouncementPlanner.plan(
        lanes: [lane], dueLaneIDs: ["research"],
        voiceMode: .titleAndSummary, completionsAreDue: false
    )

    #expect(titleOnly.spoken == withSummary.spoken)
    #expect(titleOnly.spoken == "Heads up. Research has a question for you.")
}

@Test func noDueInputPreservesCompletionSpeechDecision() {
    let lane = inputLane(id: "build", title: "Build", kind: .approval)

    let plan = InputAttentionAnnouncementPlanner.plan(
        lanes: [lane], dueLaneIDs: [],
        voiceMode: .titleOnly, completionsAreDue: true
    )

    #expect(plan.spoken == nil)
    #expect(plan.notifications.isEmpty)
    #expect(plan.shouldSpeakCompletions == true)
}
