import Foundation
import Testing
@testable import NextUpCore

private let hintedLane = AttentionHintIdentity(
    workspacePersistentID: "workspace-uuid",
    workspaceRef: "workspace:1",
    surfacePersistentID: "surface-uuid",
    surfaceRef: "surface:1"
)

private let otherHintedLane = AttentionHintIdentity(
    workspacePersistentID: "workspace-uuid",
    workspaceRef: "workspace:1",
    surfacePersistentID: "surface-other-uuid",
    surfaceRef: "surface:2"
)

private func hintedLane(uuid: String?) -> AttentionHintIdentity {
    AttentionHintIdentity(
        workspacePersistentID: "workspace-uuid",
        workspaceRef: "workspace:1",
        surfacePersistentID: uuid,
        surfaceRef: "surface:1"
    )
}

private func hintedLane(
    workspaceUUID: String? = "workspace-uuid",
    workspaceRef: String = "workspace:1",
    surfaceUUID: String? = "surface-uuid",
    surfaceRef: String = "surface:1"
) -> AttentionHintIdentity {
    AttentionHintIdentity(
        workspacePersistentID: workspaceUUID,
        workspaceRef: workspaceRef,
        surfacePersistentID: surfaceUUID,
        surfaceRef: surfaceRef
    )
}

@Test func hintDuringBaselineQuarantinesNonInputAndStartsWakeAttempt() {
    var coordinator = AttentionWakeCoordinator()
    let baseline = coordinator.beginBaselinePoll()
    #expect(baseline?.origin == .baseline)

    let scanActions = coordinator.observeSuccessfulScan([hintedLane])
    #expect(scanActions.poll == nil)

    let completion = coordinator.completePoll(
        id: baseline!.id,
        outcomes: [hintedLane: .nonInput]
    )

    #expect(completion.quarantined == [hintedLane])
    #expect(completion.poll?.origin == .wake)
    #expect(completion.poll?.attemptIdentities == [hintedLane])
    #expect(coordinator.attemptsStarted(for: hintedLane) == 1)
}

@Test func firstWakeMissSchedulesOneBoundedRetry() {
    var coordinator = AttentionWakeCoordinator()
    let wake = coordinator.observeSuccessfulScan([hintedLane]).poll
    #expect(wake?.origin == .wake)

    let completion = coordinator.completePoll(
        id: wake!.id,
        outcomes: [hintedLane: .nonInput]
    )

    #expect(completion.quarantined == [hintedLane])
    #expect(completion.poll == nil)
    #expect(completion.retryAfter == 0.4)
    #expect(coordinator.attemptsStarted(for: hintedLane) == 1)
}

@Test func retryDeadlineStartsSecondWakeAttempt() {
    var coordinator = AttentionWakeCoordinator()
    let first = coordinator.observeSuccessfulScan([hintedLane]).poll!
    _ = coordinator.completePoll(id: first.id, outcomes: [hintedLane: .nonInput])

    let retry = coordinator.retryDeadline().poll

    #expect(retry?.origin == .wake)
    #expect(retry?.attemptIdentities == [hintedLane])
    #expect(coordinator.attemptsStarted(for: hintedLane) == 2)
}

@Test func staggeredRetriesKeepIndependentDeadlines() {
    var coordinator = AttentionWakeCoordinator()
    let first = coordinator.observeSuccessfulScan([hintedLane]).poll!
    let firstMiss = coordinator.completePoll(
        id: first.id,
        outcomes: [hintedLane: .nonInput]
    )
    let secondWarning = coordinator.observeSuccessfulScan([hintedLane, otherHintedLane]).poll!
    let secondMiss = coordinator.completePoll(
        id: secondWarning.id,
        outcomes: [hintedLane: .missing, otherHintedLane: .nonInput]
    )

    let firstRetry = coordinator.retryDeadline(id: firstMiss.retry!.id).poll

    #expect(firstMiss.retry?.delay == 0.4)
    #expect(secondMiss.retry?.delay == 0.4)
    #expect(firstMiss.retry?.id != secondMiss.retry?.id)
    #expect(firstRetry?.attemptIdentities == [hintedLane])
    #expect(coordinator.attemptsStarted(for: hintedLane) == 2)
    #expect(coordinator.attemptsStarted(for: otherHintedLane) == 1)
}

@Test func retryDeadlineDuringBaselineRunsWhenBaselineClears() {
    var coordinator = AttentionWakeCoordinator()
    let first = coordinator.observeSuccessfulScan([hintedLane]).poll!
    _ = coordinator.completePoll(id: first.id, outcomes: [hintedLane: .nonInput])
    let baseline = coordinator.beginBaselinePoll()!

    #expect(coordinator.retryDeadline().poll == nil)
    let completion = coordinator.completePoll(
        id: baseline.id,
        outcomes: [hintedLane: .nonInput]
    )

    #expect(completion.quarantined == [hintedLane])
    #expect(completion.poll?.origin == .wake)
    #expect(completion.poll?.attemptIdentities == [hintedLane])
    #expect(coordinator.attemptsStarted(for: hintedLane) == 2)
}

@Test func warningDisappearanceDuringPollTombstonesResult() {
    var coordinator = AttentionWakeCoordinator()
    let baseline = coordinator.beginBaselinePoll()!
    _ = coordinator.observeSuccessfulScan([hintedLane])
    _ = coordinator.observeSuccessfulScan([])

    let completion = coordinator.completePoll(
        id: baseline.id,
        outcomes: [hintedLane: .nonInput]
    )

    #expect(completion.quarantined == [hintedLane])
    #expect(completion.poll == nil)
    #expect(completion.retryAfter == nil)
    #expect(coordinator.attemptsStarted(for: hintedLane) == 0)
}

@Test func stickyUUIDPreventsIdentityLaunderingThroughMissingObservation() {
    var coordinator = AttentionWakeCoordinator()
    let firstIdentity = hintedLane(uuid: "uuid-a")
    let first = coordinator.observeSuccessfulScan([firstIdentity]).poll!
    _ = coordinator.completePoll(id: first.id, outcomes: [firstIdentity: .inputRequired])

    let missingID = coordinator.observeSuccessfulScan([hintedLane(uuid: nil)])
    #expect(missingID.poll == nil)

    let replacement = coordinator.observeSuccessfulScan([hintedLane(uuid: "uuid-b")])
    #expect(replacement.poll?.origin == .wake)
    #expect(replacement.poll?.attemptIdentities == [hintedLane(uuid: "uuid-b")])
}

@Test func twoAttemptCapRearmsOnlyAfterWarningDisappears() {
    var coordinator = AttentionWakeCoordinator()
    let first = coordinator.observeSuccessfulScan([hintedLane]).poll!
    let firstMiss = coordinator.completePoll(id: first.id, outcomes: [hintedLane: .nonInput])
    #expect(firstMiss.retryAfter == 0.4)
    let second = coordinator.retryDeadline().poll!
    let secondMiss = coordinator.completePoll(id: second.id, outcomes: [hintedLane: .nonInput])

    #expect(secondMiss.retryAfter == nil)
    #expect(secondMiss.poll == nil)
    #expect(coordinator.observeSuccessfulScan([hintedLane]).poll == nil)

    _ = coordinator.observeSuccessfulScan([])
    let rearmed = coordinator.observeSuccessfulScan([hintedLane]).poll
    #expect(rearmed?.attemptIdentities == [hintedLane])
    #expect(coordinator.attemptsStarted(for: hintedLane) == 1)
}

@Test func cappedWarningIsProcessedNormallyByLaterBaseline() {
    var coordinator = AttentionWakeCoordinator()
    let first = coordinator.observeSuccessfulScan([hintedLane]).poll!
    _ = coordinator.completePoll(id: first.id, outcomes: [hintedLane: .nonInput])
    let second = coordinator.retryDeadline().poll!
    _ = coordinator.completePoll(id: second.id, outcomes: [hintedLane: .nonInput])

    let baseline = coordinator.beginBaselinePoll()!
    let completion = coordinator.completePoll(
        id: baseline.id,
        outcomes: [hintedLane: .nonInput]
    )

    #expect(completion.quarantined.isEmpty)
}

@Test func baselinePollFailurePreservesPostStartHintAndStartsWakeAttempt() {
    var coordinator = AttentionWakeCoordinator()
    let baseline = coordinator.beginBaselinePoll()!
    _ = coordinator.observeSuccessfulScan([hintedLane])

    let failure = coordinator.failPoll(id: baseline.id)

    #expect(failure.poll?.origin == .wake)
    #expect(failure.poll?.attemptIdentities == [hintedLane])
    #expect(coordinator.attemptsStarted(for: hintedLane) == 1)
}

@Test func stableUUIDWithChangedRefsContinuesSameWarning() {
    var coordinator = AttentionWakeCoordinator()
    let original = hintedLane(workspaceRef: "workspace:old", surfaceRef: "surface:old")
    let first = coordinator.observeSuccessfulScan([original]).poll!
    _ = coordinator.completePoll(id: first.id, outcomes: [original: .inputRequired])

    let moved = hintedLane(workspaceRef: "workspace:new", surfaceRef: "surface:new")
    let scan = coordinator.observeSuccessfulScan([moved])

    #expect(scan.poll == nil)
    #expect(coordinator.attemptsStarted(for: moved) == 1)
}

@Test func readFailedWakeAttemptQuarantinesAndSchedulesRetry() {
    var coordinator = AttentionWakeCoordinator()
    let wake = coordinator.observeSuccessfulScan([hintedLane]).poll!

    let completion = coordinator.completePoll(
        id: wake.id,
        outcomes: [hintedLane: .readFailed]
    )

    #expect(completion.quarantined == [hintedLane])
    #expect(completion.retryAfter == 0.4)
}

@Test func failedTopologyScanPreservesSatisfiedWarningWithoutRearming() {
    var coordinator = AttentionWakeCoordinator()
    let wake = coordinator.observeSuccessfulScan([hintedLane]).poll!
    _ = coordinator.completePoll(id: wake.id, outcomes: [hintedLane: .inputRequired])

    let failure = coordinator.observeFailedScan()
    let unchanged = coordinator.observeSuccessfulScan([hintedLane])

    #expect(failure.poll == nil)
    #expect(unchanged.poll == nil)
    #expect(coordinator.attemptsStarted(for: hintedLane) == 1)
}

@Test func stopInvalidatesLatePollAndScanThenRestartRearms() {
    var coordinator = AttentionWakeCoordinator()
    let generation = coordinator.generation
    let wake = coordinator.observeSuccessfulScan([hintedLane], generation: generation).poll!

    coordinator.stop()
    let latePoll = coordinator.completePoll(id: wake.id, outcomes: [hintedLane: .inputRequired])
    let lateScan = coordinator.observeSuccessfulScan([hintedLane], generation: generation)
    coordinator.start()
    let restarted = coordinator.observeSuccessfulScan(
        [hintedLane],
        generation: coordinator.generation
    )

    #expect(latePoll.poll == nil)
    #expect(lateScan.poll == nil)
    #expect(restarted.poll?.origin == .wake)
    #expect(coordinator.attemptsStarted(for: hintedLane) == 1)
}

@Test func baselineObservationDoesNotResetExistingRetryDeadline() {
    var coordinator = AttentionWakeCoordinator()
    let first = coordinator.observeSuccessfulScan([hintedLane]).poll!
    _ = coordinator.completePoll(id: first.id, outcomes: [hintedLane: .nonInput])
    let baseline = coordinator.beginBaselinePoll()!

    let completion = coordinator.completePoll(
        id: baseline.id,
        outcomes: [hintedLane: .nonInput]
    )

    #expect(completion.quarantined == [hintedLane])
    #expect(completion.retryAfter == nil)
    #expect(coordinator.retryDeadline().poll?.attemptIdentities == [hintedLane])
}

@Test func postStartHintInputDuringBaselineSatisfiesWithoutWakeAttempt() {
    var coordinator = AttentionWakeCoordinator()
    let baseline = coordinator.beginBaselinePoll()!
    _ = coordinator.observeSuccessfulScan([hintedLane])

    let completion = coordinator.completePoll(
        id: baseline.id,
        outcomes: [hintedLane: .inputRequired]
    )

    #expect(completion.quarantined.isEmpty)
    #expect(completion.poll == nil)
    #expect(coordinator.attemptsStarted(for: hintedLane) == 0)
}

@Test(arguments: [
    AttentionPollLaneOutcome.nonInput,
    .missing,
    .readFailed,
])
func postStartHintMissDuringUnrelatedWakeStaysQuarantined(
    outcome: AttentionPollLaneOutcome
) {
    var coordinator = AttentionWakeCoordinator()
    let unrelatedWake = coordinator.observeSuccessfulScan([otherHintedLane]).poll!
    _ = coordinator.observeSuccessfulScan([otherHintedLane, hintedLane])

    let completion = coordinator.completePoll(
        id: unrelatedWake.id,
        outcomes: [otherHintedLane: .inputRequired, hintedLane: outcome]
    )

    #expect(completion.quarantined == [hintedLane])
    #expect(completion.poll?.attemptIdentities == [hintedLane])
    #expect(coordinator.attemptsStarted(for: hintedLane) == 1)
}

@Test func postStartHintInputDuringUnrelatedWakeSatisfiesWithoutFollowUp() {
    var coordinator = AttentionWakeCoordinator()
    let unrelatedWake = coordinator.observeSuccessfulScan([otherHintedLane]).poll!
    _ = coordinator.observeSuccessfulScan([otherHintedLane, hintedLane])

    let completion = coordinator.completePoll(
        id: unrelatedWake.id,
        outcomes: [otherHintedLane: .inputRequired, hintedLane: .inputRequired]
    )

    #expect(completion.quarantined.isEmpty)
    #expect(completion.poll == nil)
    #expect(coordinator.attemptsStarted(for: hintedLane) == 0)
}

@Test func postStartHintDuringFailedUnrelatedWakeStillGetsFollowUp() {
    var coordinator = AttentionWakeCoordinator()
    let unrelatedWake = coordinator.observeSuccessfulScan([otherHintedLane]).poll!
    _ = coordinator.observeSuccessfulScan([otherHintedLane, hintedLane])

    let failure = coordinator.failPoll(id: unrelatedWake.id)

    #expect(failure.poll?.attemptIdentities == [hintedLane])
    #expect(failure.retryAfter == 0.4)
    #expect(coordinator.attemptsStarted(for: hintedLane) == 1)
}

@Test func disappearingPostStartHintTombstonesUnrelatedWakeResult() {
    var coordinator = AttentionWakeCoordinator()
    let unrelatedWake = coordinator.observeSuccessfulScan([otherHintedLane]).poll!
    _ = coordinator.observeSuccessfulScan([otherHintedLane, hintedLane])
    _ = coordinator.observeSuccessfulScan([otherHintedLane])

    let completion = coordinator.completePoll(
        id: unrelatedWake.id,
        outcomes: [otherHintedLane: .inputRequired, hintedLane: .inputRequired]
    )

    #expect(completion.quarantined == [hintedLane])
    #expect(completion.poll == nil)
    #expect(coordinator.attemptsStarted(for: hintedLane) == 0)
}

@Test func retryDeadlineDuringBaselineInputSatisfiesWithoutSecondAttempt() {
    var coordinator = AttentionWakeCoordinator()
    let first = coordinator.observeSuccessfulScan([hintedLane]).poll!
    _ = coordinator.completePoll(id: first.id, outcomes: [hintedLane: .nonInput])
    let baseline = coordinator.beginBaselinePoll()!
    _ = coordinator.retryDeadline()

    let completion = coordinator.completePoll(
        id: baseline.id,
        outcomes: [hintedLane: .inputRequired]
    )

    #expect(completion.poll == nil)
    #expect(coordinator.retryDeadline().poll == nil)
    #expect(coordinator.attemptsStarted(for: hintedLane) == 1)
}

@Test func retryDueIsServicedAfterCollidingPollFailure() {
    var coordinator = AttentionWakeCoordinator()
    let first = coordinator.observeSuccessfulScan([hintedLane]).poll!
    _ = coordinator.completePoll(id: first.id, outcomes: [hintedLane: .nonInput])
    let baseline = coordinator.beginBaselinePoll()!
    _ = coordinator.retryDeadline()

    let failure = coordinator.failPoll(id: baseline.id)

    #expect(failure.poll?.attemptIdentities == [hintedLane])
    #expect(coordinator.attemptsStarted(for: hintedLane) == 2)
}

@Test func retryDeadlineDuringUnrelatedWakeCoalescesAfterCompletion() {
    var coordinator = AttentionWakeCoordinator()
    let first = coordinator.observeSuccessfulScan([hintedLane]).poll!
    _ = coordinator.completePoll(id: first.id, outcomes: [hintedLane: .nonInput])
    let unrelated = coordinator.observeSuccessfulScan([hintedLane, otherHintedLane]).poll!
    _ = coordinator.retryDeadline()

    let completion = coordinator.completePoll(
        id: unrelated.id,
        outcomes: [hintedLane: .missing, otherHintedLane: .inputRequired]
    )

    #expect(completion.quarantined == [hintedLane])
    #expect(completion.poll?.attemptIdentities == [hintedLane])
    #expect(coordinator.attemptsStarted(for: hintedLane) == 2)
}

@Test func disappearanceExposesScheduledRetryTokenAsCanceled() {
    var coordinator = AttentionWakeCoordinator()
    let first = coordinator.observeSuccessfulScan([hintedLane]).poll!
    let miss = coordinator.completePoll(id: first.id, outcomes: [hintedLane: .missing])
    let retryID = miss.retry!.id
    #expect(coordinator.isRetryActive(id: retryID))

    _ = coordinator.observeSuccessfulScan([])

    #expect(!coordinator.isRetryActive(id: retryID))
    #expect(coordinator.retryDeadline(id: retryID).poll == nil)
    #expect(coordinator.attemptsStarted(for: hintedLane) == 0)
}

@Test func pollFailuresAreCappedAtTwoAttempts() {
    var coordinator = AttentionWakeCoordinator()
    let first = coordinator.observeSuccessfulScan([hintedLane]).poll!
    let firstFailure = coordinator.failPoll(id: first.id)
    let second = coordinator.retryDeadline().poll!
    let secondFailure = coordinator.failPoll(id: second.id)

    #expect(firstFailure.retryAfter == 0.4)
    #expect(secondFailure.retryAfter == nil)
    #expect(secondFailure.poll == nil)
    #expect(coordinator.attemptsStarted(for: hintedLane) == 2)
}

@Test func warningDisappearanceTombstonesInputFromCapturedWakeAttempt() {
    var coordinator = AttentionWakeCoordinator()
    let wake = coordinator.observeSuccessfulScan([hintedLane]).poll!
    _ = coordinator.observeSuccessfulScan([])

    let completion = coordinator.completePoll(
        id: wake.id,
        outcomes: [hintedLane: .inputRequired]
    )

    #expect(completion.quarantined == [hintedLane])
    #expect(completion.retryAfter == nil)
    #expect(completion.poll == nil)
}

@Test func refOnlyIdentityUpgradesToUUIDWhenRefIsStable() {
    var coordinator = AttentionWakeCoordinator()
    let refOnly = hintedLane(surfaceUUID: nil)
    let first = coordinator.observeSuccessfulScan([refOnly]).poll!
    _ = coordinator.completePoll(id: first.id, outcomes: [refOnly: .inputRequired])
    let upgraded = hintedLane(surfaceUUID: "surface-learned")

    #expect(coordinator.observeSuccessfulScan([upgraded]).poll == nil)
    #expect(coordinator.attemptsStarted(for: upgraded) == 1)
}

@Test func refOnlyIdentityWithUUIDAndChangedRefIsNew() {
    var coordinator = AttentionWakeCoordinator()
    let refOnly = hintedLane(surfaceUUID: nil, surfaceRef: "surface:old")
    let first = coordinator.observeSuccessfulScan([refOnly]).poll!
    _ = coordinator.completePoll(id: first.id, outcomes: [refOnly: .inputRequired])
    let replacement = hintedLane(surfaceUUID: "surface-new", surfaceRef: "surface:new")

    #expect(coordinator.observeSuccessfulScan([replacement]).poll?.attemptIdentities == [replacement])
}

@Test func workspaceStickyUUIDPreventsLaunderingThroughMissingObservation() {
    var coordinator = AttentionWakeCoordinator()
    let original = hintedLane(workspaceUUID: "workspace-a")
    let first = coordinator.observeSuccessfulScan([original]).poll!
    _ = coordinator.completePoll(id: first.id, outcomes: [original: .inputRequired])
    let missing = hintedLane(workspaceUUID: nil)
    #expect(coordinator.observeSuccessfulScan([missing]).poll == nil)
    let replacement = hintedLane(workspaceUUID: "workspace-b")

    #expect(coordinator.observeSuccessfulScan([replacement]).poll?.attemptIdentities == [replacement])
}

@Test func sameSurfaceIdentityInDifferentWorkspaceIsNew() {
    var coordinator = AttentionWakeCoordinator()
    let original = hintedLane(workspaceUUID: "workspace-a", workspaceRef: "workspace:a")
    let first = coordinator.observeSuccessfulScan([original]).poll!
    _ = coordinator.completePoll(id: first.id, outcomes: [original: .inputRequired])
    let otherWorkspace = hintedLane(workspaceUUID: "workspace-b", workspaceRef: "workspace:b")

    #expect(coordinator.observeSuccessfulScan([otherWorkspace]).poll?.attemptIdentities == [otherWorkspace])
}

@Test func hintScansDoNotOverlapAndFailureLeavesTopologyUntouched() {
    var coordinator = AttentionWakeCoordinator()
    let initial = coordinator.observeSuccessfulScan([hintedLane]).poll!
    _ = coordinator.completePoll(id: initial.id, outcomes: [hintedLane: .inputRequired])
    let scan = coordinator.beginHintScan()!

    #expect(coordinator.beginHintScan() == nil)
    #expect(coordinator.failHintScan(id: scan.id, generation: scan.generation).poll == nil)
    let nextScan = coordinator.beginHintScan()!
    #expect(coordinator.completeHintScan(
        id: nextScan.id,
        generation: nextScan.generation,
        observations: [hintedLane]
    ).poll == nil)
}

@Test func pollOutcomeWithoutUUIDMatchesStickyIdentityByStableRefs() {
    var coordinator = AttentionWakeCoordinator()
    let wake = coordinator.observeSuccessfulScan([hintedLane]).poll!
    let temporarilyMissingUUID = AttentionHintIdentity(
        workspacePersistentID: nil,
        workspaceRef: hintedLane.workspaceRef,
        surfacePersistentID: nil,
        surfaceRef: hintedLane.surfaceRef
    )

    let completion = coordinator.completePoll(
        id: wake.id,
        outcomes: [temporarilyMissingUUID: .inputRequired]
    )

    #expect(completion.quarantined.isEmpty)
    #expect(completion.retryAfter == nil)
    #expect(coordinator.retryDeadline().poll == nil)
}
