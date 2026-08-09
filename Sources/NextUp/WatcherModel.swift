import AppKit
import Foundation
import NextUpCore
import UserNotifications

enum NextUpNotification {
    static let completionCategoryID = "NEXT_UP_COMPLETION"
    static let inputRequiredCategoryID = "NEXT_UP_INPUT_REQUIRED"
    static let markSeenActionID = "NEXT_UP_MARK_SEEN"
}

enum WatcherPollStateApplicator {
    static func apply(
        snapshots: [LaneSnapshot],
        quarantinedLaneIDs: Set<String>,
        liveLaneIDs: Set<String>,
        state: inout LaneMonitorState,
        observationSession: inout LaneObservationSession,
        attentionTracker: inout InputAttentionTracker,
        now: Date
    ) {
        let authoritative = snapshots.filter { !quarantinedLaneIDs.contains($0.id) }
        let preservedAttention = attentionTracker.activeLaneIDs.intersection(quarantinedLaneIDs)
        let preservedSnapshots = preservedAttention.map { laneID in
            snapshots.first(where: { $0.id == laneID && $0.state == .inputRequired })
                ?? LaneSnapshot(id: laneID, title: "Input required", state: .inputRequired)
        }
        attentionTracker.observe(authoritative + preservedSnapshots)

        let rememberedLaneIDs = Set(state.previous.keys).union(state.pending.map(\.laneID))
        state.forget(laneIDs: rememberedLaneIDs.subtracting(liveLaneIDs))
        observationSession.retain(liveLaneIDs: liveLaneIDs)
        observationSession.observe(authoritative, state: &state, now: now)
    }

    static func resetAuthoritativeBaselines(
        observationSession: inout LaneObservationSession
    ) {
        observationSession = LaneObservationSession()
    }
}

@MainActor
final class WatcherModel: ObservableObject {
    @Published private(set) var pending: [PendingCompletion] = []
    @Published private(set) var attentionLaneIDs: Set<String> = []
    @Published private(set) var lanes: [LaneSnapshot] = []
    @Published private(set) var workspaces: [WorkspaceInfo] = []
    @Published private(set) var selection: WorkspaceSelection
    @Published private(set) var voiceMode: VoiceAnnouncementMode
    @Published private(set) var status = "Starting…"

    var onUpdate: (() -> Void)?

    private let client = CMUXClient()
    private let pollInterval: TimeInterval = 5
    private let stateURL: URL
    private let selectionURL: URL
    private let voicePreferencesURL: URL
    private let activityDatesURL: URL
    private let inputAttentionStateURL: URL
    private let transactionStateStore: WatcherTransactionStateStore
    private let sessionService: HermesSessionService
    private var state: LaneMonitorState
    private var observationSession = LaneObservationSession()
    private var attentionTracker = InputAttentionTracker()
    private var pollReceiptState: PollReceiptState
    private var transactionState: WatcherTransactionState
    private var activityDates: [String: Date] = [:]
    private var pollTimer: Timer?
    private var hintTimer: Timer?
    private var isRunning = false
    private let speech = NSSpeechSynthesizer()
    private lazy var pollingRuntime = WatcherPollingRuntime(
        fetchInventory: { [client] in try client.fetchInventory() },
        fetchPoll: { [client] selection in try client.fetch(selection: selection) },
        selection: { [weak self] in self?.selection ?? WorkspaceSelection() },
        priorSnapshots: { [weak self] in self?.lanes ?? [] },
        focusEligibility: { [weak self] in
            guard let self else { return [] }
            return WatcherFocusReconciliation.eligibleAlerts(
                state: self.state,
                attentionTracker: self.attentionTracker
            )
        },
        acquireFreshFocus: { [client] in client.acquireFreshFocus() },
        preEnrichmentReconcile: { [weak self] result in
            self?.reconcileExistingFocusBeforeEnrichment(result) ?? result
        },
        apply: { [weak self] result in await self?.applyPollResult(result) ?? result.lanes },
        failed: { [weak self] message in self?.pollFailed(message) }
    )

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NextUp", isDirectory: true)
        stateURL = base.appendingPathComponent("state.json")
        selectionURL = base.appendingPathComponent("workspace-selection.json")
        voicePreferencesURL = base.appendingPathComponent("voice-preferences.json")
        activityDatesURL = base.appendingPathComponent("activity-dates.json")
        inputAttentionStateURL = base.appendingPathComponent("input-attention-state.json")
        let transactionStore = WatcherTransactionStateStore(
            url: base.appendingPathComponent("watcher-transaction.json")
        )
        sessionService = HermesSessionService(
            cacheURL: base.appendingPathComponent("session-bindings.json")
        )
        if let data = try? Data(contentsOf: selectionURL),
           let restoredSelection = try? JSONDecoder().decode(WorkspaceSelection.self, from: data) {
            selection = restoredSelection
        } else {
            selection = WorkspaceSelection()
        }
        if let data = try? Data(contentsOf: voicePreferencesURL),
           let preferences = try? JSONDecoder().decode(VoicePreferences.self, from: data) {
            voiceMode = preferences.mode
        } else {
            voiceMode = .titleAndSummary
        }
        let legacyState: LaneMonitorState
        if let data = try? Data(contentsOf: stateURL),
           let restored = try? JSONDecoder().decode(LaneMonitorState.self, from: data) {
            legacyState = restored
        } else {
            legacyState = LaneMonitorState()
        }
        if let data = try? Data(contentsOf: activityDatesURL),
           let restoredActivityDates = try? JSONDecoder().decode([String: Date].self, from: data) {
            activityDates = restoredActivityDates
        }
        let legacyAttention = InputAttentionStateStore(url: inputAttentionStateURL).load()
        let transaction = transactionStore.load(
            legacyLaneMonitorState: legacyState,
            legacyInputAttentionTracker: legacyAttention
        )
        transactionStateStore = transactionStore
        transactionState = transaction
        state = transaction.laneMonitorState
        attentionTracker = transaction.inputAttentionTracker
        pollReceiptState = transaction.pollReceiptState
        pending = state.pending
    }

    private func reconcileExistingFocusBeforeEnrichment(_ pollResult: CMUXPollResult) -> CMUXPollResult {
        let currentAlerts = WatcherFocusReconciliation.eligibleAlerts(
            state: state,
            attentionTracker: attentionTracker
        )
        let stillEligible = pollResult.focusEligibility.filter { requested in
            currentAlerts.contains { WatcherFocusReconciliation.sameIdentity(requested, $0) }
        }
        let plan = WatcherFocusReconciliation.plan(
            eligibleAlerts: stillEligible,
            observation: pollResult.focusObservation,
            reconciledAt: Date()
        )
        guard !plan.suppressions.isEmpty else { return pollResult }
        var proposedState = state
        var proposedTracker = attentionTracker
        let acknowledged = WatcherFocusAcknowledgementApplicator.apply(
            laneIDs: Set(plan.suppressions.map(\.laneID)),
            state: &proposedState,
            attentionTracker: &proposedTracker
        )
        guard !acknowledged.isEmpty else { return pollResult }
        do {
            let committed = try transactionStateStore.commitAcknowledgement(
                from: transactionState,
                laneMonitorState: proposedState,
                inputAttentionTracker: proposedTracker
            )
            transactionState = committed
            state = committed.laneMonitorState
            attentionTracker = committed.inputAttentionTracker
            pollReceiptState = committed.pollReceiptState
            pending = state.pending
            attentionLaneIDs = attentionTracker.activeLaneIDs
            removeDeliveredNotifications(for: acknowledged)
            return pollResult.carrying(preEnrichmentFocusPlan: plan)
        } catch {
            pollFailed("could not commit focused acknowledgement")
            return pollResult
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        diagnostic("app started")
        let center = UNUserNotificationCenter.current()
        let markSeen = UNNotificationAction(
            identifier: NextUpNotification.markSeenActionID,
            title: "Mark Seen"
        )
        let completionCategory = UNNotificationCategory(
            identifier: NextUpNotification.completionCategoryID,
            actions: [markSeen],
            intentIdentifiers: []
        )
        let inputRequiredCategory = UNNotificationCategory(
            identifier: NextUpNotification.inputRequiredCategoryID,
            actions: [markSeen],
            intentIdentifiers: []
        )
        center.setNotificationCategories([completionCategory, inputRequiredCategory])
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        pollingRuntime.start()
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        hintTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollingRuntime.hintScanTick() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
        hintTimer?.invalidate()
        hintTimer = nil
        pollingRuntime.stop()
        WatcherPollStateApplicator.resetAuthoritativeBaselines(
            observationSession: &observationSession
        )
    }

    func poll() {
        if workspaces.isEmpty { diagnostic("first poll started") }
        pollingRuntime.baselineTick()
    }

    private func pollFailed(_ message: String) {
        diagnostic("poll failed: \(message)")
        status = "Watcher error: \(message)"
        onUpdate?()
    }

    private func applyPollResult(_ pollResult: CMUXPollResult) async -> [LaneSnapshot] {
        let isFirstPoll = workspaces.isEmpty
        let now = Date()
        let alertsBeforeApply = WatcherFocusReconciliation.eligibleAlerts(
            state: state,
            attentionTracker: attentionTracker
        )
        let previouslyAttendingLaneIDs = attentionTracker.activeLaneIDs
        let previouslyPendingLaneIDs = Set(state.pending.map(\.laneID))
        let eligibleLanes = pollResult.lanes.filter {
            !pollResult.quarantinedLaneIDs.contains($0.id)
        }
        let completionCandidateIDs = Set(eligibleLanes.compactMap { lane in
            observationSession.hasBaseline(for: lane.id) &&
                state.previous[lane.id] == .busy && lane.state == .ready ? lane.id : nil
        })
        let liveSurfacePersistentIDs = Set(pollResult.inventory
            .filter { selection.isSelected($0.info.id) }
            .flatMap(\.lanes)
            .compactMap(\.persistentID))
        let enrichment = await sessionService.enrich(
            lanes: eligibleLanes,
            completionCandidateIDs: completionCandidateIDs,
            retainingSurfacePersistentIDs: liveSurfacePersistentIDs,
            now: now
        )
        guard !Task.isCancelled else { return lanes }
        let enrichedByID = Dictionary(uniqueKeysWithValues: enrichment.lanes.map { ($0.id, $0) })
        let snapshots = pollResult.lanes.map { lane in
            pollResult.quarantinedLaneIDs.contains(lane.id) ? lane : (enrichedByID[lane.id] ?? lane)
        }
        var proposedState = state
        var proposedObservationSession = observationSession
        var proposedAttentionTracker = attentionTracker
        let existingFocusPlan = pollResult.preEnrichmentFocusPlan
        let proposedActivityDates = LaneActivityHistory.updatedDates(
            existing: activityDates,
            previous: lanes,
            current: snapshots,
            now: now
        )
        let liveLaneIDs = Set(pollResult.inventory
            .filter { selection.isSelected($0.info.id) }
            .flatMap(\.lanes)
            .map(\.id))
        WatcherPollStateApplicator.apply(
            snapshots: snapshots,
            quarantinedLaneIDs: pollResult.quarantinedLaneIDs,
            liveLaneIDs: liveLaneIDs,
            state: &proposedState,
            observationSession: &proposedObservationSession,
            attentionTracker: &proposedAttentionTracker,
            now: now
        )
        let alertsAfterApply = WatcherFocusReconciliation.eligibleAlerts(
            state: proposedState,
            attentionTracker: proposedAttentionTracker
        )
        let newAlerts = WatcherFocusReconciliation.newlyCreatedAlerts(
            previousAlerts: alertsBeforeApply,
            currentAlerts: alertsAfterApply
        )
        let ordinaryDeliveryState = proposedState
        let ordinaryDeliveryTracker = proposedAttentionTracker
        _ = WatcherFocusAcknowledgementApplicator.apply(
            laneIDs: Set(existingFocusPlan.suppressions.map(\.laneID)),
            state: &proposedState,
            attentionTracker: &proposedAttentionTracker
        )
        var newFocusPlan = FocusSuppressionPlan.empty
        if !newAlerts.isEmpty {
            let client = self.client
            let observation = await Task.detached {
                client.acquireFreshFocus()
            }.value
            guard !Task.isCancelled else { return lanes }
            newFocusPlan = WatcherFocusReconciliation.plan(
                eligibleAlerts: newAlerts,
                observation: observation,
                reconciledAt: Date()
            )
            _ = WatcherFocusAcknowledgementApplicator.apply(
                laneIDs: Set(newFocusPlan.suppressions.map(\.laneID)),
                state: &proposedState,
                attentionTracker: &proposedAttentionTracker
            )
        }
        var proposedReceiptState: PollReceiptState
        var pollTransactionCommitted = false
        do {
            let committed = try transactionStateStore.commitPoll(
                from: transactionState,
                pollKind: pollResult.pollKind,
                laneMonitorState: proposedState,
                inputAttentionTracker: proposedAttentionTracker,
                suppressionPlans: [existingFocusPlan, newFocusPlan]
            )
            transactionState = committed
            proposedReceiptState = committed.pollReceiptState
            pollTransactionCommitted = true
        } catch {
            pollFailed("could not commit focus receipt")
            // Fail open for delivery. No receipt or sequence is published, and
            // the unsuppressed alert state is what subsequent persistence uses.
            proposedState = ordinaryDeliveryState
            proposedAttentionTracker = ordinaryDeliveryTracker
            proposedReceiptState = pollReceiptState
            if let committed = try? transactionStateStore.commitPoll(
                from: transactionState,
                pollKind: pollResult.pollKind,
                laneMonitorState: proposedState,
                inputAttentionTracker: proposedAttentionTracker,
                suppressionPlans: []
            ) {
                transactionState = committed
                proposedReceiptState = committed.pollReceiptState
                pollTransactionCommitted = true
            }
        }
        workspaces = pollResult.workspaces
        activityDates = proposedActivityDates
        lanes = snapshots
        state = proposedState
        observationSession = proposedObservationSession
        attentionTracker = proposedAttentionTracker
        pollReceiptState = proposedReceiptState
        transactionState = WatcherTransactionState(
            laneMonitorState: proposedState,
            inputAttentionTracker: proposedAttentionTracker,
            pollReceiptState: proposedReceiptState
        )
        attentionLaneIDs = attentionTracker.activeLaneIDs
        removeDeliveredNotifications(
            for: previouslyAttendingLaneIDs.subtracting(attentionLaneIDs)
        )
        let currentlyPendingLaneIDs = Set(state.pending.map(\.laneID))
        removeDeliveredNotifications(for: previouslyPendingLaneIDs.subtracting(currentlyPendingLaneIDs))
        let dueAttentionLaneIDs = Set(
            attentionTracker.due(at: now)
        ).subtracting(pollResult.quarantinedLaneIDs)
        let due = state.completionsDueForAnnouncement(at: now)
            .filter { !pollResult.quarantinedLaneIDs.contains($0.laneID) }
        let attentionPlan = InputAttentionAnnouncementPlanner.plan(
            lanes: snapshots,
            dueLaneIDs: dueAttentionLaneIDs,
            voiceMode: voiceMode,
            completionsAreDue: !due.isEmpty
        )
        if !attentionPlan.notifications.isEmpty {
            announceInputRequired(attentionPlan)
            attentionTracker.markAnnounced(laneIDs: dueAttentionLaneIDs, at: now)
        }
        if !due.isEmpty {
            announce(due, speak: attentionPlan.shouldSpeakCompletions)
            state.markAnnounced(laneIDs: Set(due.map(\.laneID)), at: now)
        }
        pending = state.pending
        let selectedCount = pollResult.workspaces.filter { selection.isSelected($0.id) }.count
        status = "Watching \(selectedCount) of \(pollResult.workspaces.count) workspaces · \(snapshots.count) lanes · \(enrichment.bindingCount) sessions bound"
        if isFirstPoll {
            diagnostic("first poll completed: \(selectedCount) workspaces, \(snapshots.count) lanes")
        }
        persist(commitCanonical: pollTransactionCommitted)
        onUpdate?()
        return snapshots
    }

    func isWorkspaceSelected(_ workspaceID: String) -> Bool {
        selection.isSelected(workspaceID)
    }

    func activityDate(for laneID: String) -> Date? {
        let key = lanes.first(where: { $0.id == laneID }).map(activityKey(for:)) ?? laneID
        return pending.first(where: { $0.laneID == laneID })?.completedAt ?? activityDates[key]
    }

    func toggleWorkspace(_ workspaceID: String) {
        let wasSelected = selection.isSelected(workspaceID)
        selection.toggle(workspaceID)
        if wasSelected {
            let removedLanes = lanes.filter { $0.workspaceID == workspaceID }
            let laneIDs = Set(removedLanes.map(\.id))
            for lane in removedLanes {
                activityDates.removeValue(forKey: activityKey(for: lane))
            }
            state.forget(laneIDs: laneIDs)
            removeDeliveredNotifications(for: laneIDs)
            lanes.removeAll { $0.workspaceID == workspaceID }
            pending = state.pending
            persist()
        }
        persistSelection()
        onUpdate?()
        poll()
    }

    func selectAllWorkspaces() {
        selection.selectAll()
        persistSelection()
        onUpdate?()
        poll()
    }

    func setVoiceMode(_ mode: VoiceAnnouncementMode) {
        voiceMode = mode
        persistVoicePreferences()
        onUpdate?()
    }

    func acknowledge(_ laneID: String) {
        var proposedState = state
        var proposedTracker = attentionTracker
        let acknowledged = WatcherFocusAcknowledgementApplicator.apply(
            laneIDs: [laneID],
            state: &proposedState,
            attentionTracker: &proposedTracker
        )
        guard commitAlertState(
            laneMonitorState: proposedState,
            inputAttentionTracker: proposedTracker
        ) else { return }
        attentionLaneIDs = attentionTracker.activeLaneIDs
        removeDeliveredNotifications(for: acknowledged)
        pending = state.pending
        persist()
        onUpdate?()
    }

    func acknowledgeAll() {
        let laneIDs = Set(state.pending.map(\.laneID)).union(attentionLaneIDs)
        var proposedState = state
        var proposedTracker = attentionTracker
        let acknowledged = WatcherFocusAcknowledgementApplicator.apply(
            laneIDs: laneIDs,
            state: &proposedState,
            attentionTracker: &proposedTracker
        )
        guard commitAlertState(
            laneMonitorState: proposedState,
            inputAttentionTracker: proposedTracker
        ) else { return }
        attentionLaneIDs = attentionTracker.activeLaneIDs
        removeDeliveredNotifications(for: acknowledged)
        pending = state.pending
        persist()
        onUpdate?()
    }

    private func announceInputRequired(_ plan: InputAttentionAnnouncementPlan) {
        guard !plan.notifications.isEmpty else { return }
        if let spoken = plan.spoken {
            speech.startSpeaking(spoken)
        }

        for notification in plan.notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default
            content.categoryIdentifier = NextUpNotification.inputRequiredCategoryID
            content.userInfo = notification.userInfo
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: notification.identifier,
                content: content,
                trigger: nil
            ))
        }
    }

    private func announce(_ completions: [PendingCompletion], speak: Bool = true) {
        let now = Date()
        if speak, let spoken = VoiceAnnouncementFormatter.completions(
            completions,
            mode: voiceMode,
            at: now
        ) {
            speech.startSpeaking(spoken)
        }

        for completion in completions {
            let content = UNMutableNotificationContent()
            content.title = "\(completion.displayName) finished"
            content.body = CompletionAnnouncementFormatter.notificationBody(completion, at: now)
            content.sound = .default
            content.categoryIdentifier = NextUpNotification.completionCategoryID
            content.userInfo = NextUpNotificationUserInfo.make(
                laneID: completion.laneID,
                kind: "completion",
                navigationTarget: completion.navigationTarget
            )
            content.interruptionLevel = .active
            content.relevanceScore = 1.0
            let request = UNNotificationRequest(
                identifier: notificationIdentifier(for: completion.laneID),
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func notificationIdentifier(for laneID: String) -> String {
        "next-up-\(laneID)"
    }

    private func removeDeliveredNotifications(for laneIDs: Set<String>) {
        guard !laneIDs.isEmpty else { return }
        let identifiers = laneIDs.map(notificationIdentifier(for:))
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func diagnostic(_ message: String) {
        let line = "[NextUp] \(message)\n"
        if let data = line.data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }

    private func activityKey(for lane: LaneSnapshot) -> String {
        LaneActivityHistory.key(for: lane)
    }

    private func persistSelection() {
        do {
            try FileManager.default.createDirectory(
                at: selectionURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(selection)
            try data.write(to: selectionURL, options: .atomic)
        } catch {
            status = "Could not save workspace selection: \(error.localizedDescription)"
        }
    }

    private func persistVoicePreferences() {
        do {
            try FileManager.default.createDirectory(
                at: voicePreferencesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(VoicePreferences(mode: voiceMode))
            try data.write(to: voicePreferencesURL, options: .atomic)
        } catch {
            status = "Could not save voice preferences: \(error.localizedDescription)"
        }
    }

    private func persist(commitCanonical: Bool = true) {
        if commitCanonical {
            guard commitAlertState(
                laneMonitorState: state,
                inputAttentionTracker: attentionTracker
            ) else { return }
        }
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
            let activityData = try JSONEncoder().encode(activityDates)
            try activityData.write(to: activityDatesURL, options: .atomic)
            try InputAttentionStateStore(url: inputAttentionStateURL).save(attentionTracker)
        } catch {
            status = "Could not save watcher state: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func commitAlertState(
        laneMonitorState: LaneMonitorState,
        inputAttentionTracker: InputAttentionTracker
    ) -> Bool {
        do {
            let committed = try transactionStateStore.commitAcknowledgement(
                from: transactionState,
                laneMonitorState: laneMonitorState,
                inputAttentionTracker: inputAttentionTracker
            )
            transactionState = committed
            state = committed.laneMonitorState
            attentionTracker = committed.inputAttentionTracker
            pollReceiptState = committed.pollReceiptState
            return true
        } catch {
            status = "Could not save watcher transaction: \(error.localizedDescription)"
            return false
        }
    }
}
