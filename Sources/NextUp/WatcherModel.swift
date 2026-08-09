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
    private let sessionService: HermesSessionService
    private var state: LaneMonitorState
    private var observationSession = LaneObservationSession()
    private var attentionTracker = InputAttentionTracker()
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
        if let data = try? Data(contentsOf: stateURL),
           let restored = try? JSONDecoder().decode(LaneMonitorState.self, from: data) {
            state = restored
        } else {
            state = LaneMonitorState()
        }
        if let data = try? Data(contentsOf: activityDatesURL),
           let restoredActivityDates = try? JSONDecoder().decode([String: Date].self, from: data) {
            activityDates = restoredActivityDates
        }
        pending = state.pending
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
        workspaces = pollResult.workspaces
        activityDates = LaneActivityHistory.updatedDates(
            existing: activityDates,
            previous: lanes,
            current: snapshots,
            now: now
        )
        lanes = snapshots
        let previouslyAttendingLaneIDs = attentionTracker.activeLaneIDs
        let previouslyPendingLaneIDs = Set(state.pending.map(\.laneID))
        let liveLaneIDs = Set(pollResult.inventory
            .filter { selection.isSelected($0.info.id) }
            .flatMap(\.lanes)
            .map(\.id))
        WatcherPollStateApplicator.apply(
            snapshots: snapshots,
            quarantinedLaneIDs: pollResult.quarantinedLaneIDs,
            liveLaneIDs: liveLaneIDs,
            state: &state,
            observationSession: &observationSession,
            attentionTracker: &attentionTracker,
            now: now
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
        persist()
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
        state.acknowledge(laneID: laneID)
        attentionTracker.acknowledge(laneID: laneID)
        removeDeliveredNotifications(for: [laneID])
        pending = state.pending
        persist()
        onUpdate?()
    }

    func acknowledgeAll() {
        let laneIDs = Set(state.pending.map(\.laneID)).union(attentionLaneIDs)
        for item in state.pending {
            state.acknowledge(laneID: item.laneID)
        }
        for laneID in attentionLaneIDs {
            attentionTracker.acknowledge(laneID: laneID)
        }
        removeDeliveredNotifications(for: laneIDs)
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

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
            let activityData = try JSONEncoder().encode(activityDates)
            try activityData.write(to: activityDatesURL, options: .atomic)
        } catch {
            status = "Could not save watcher state: \(error.localizedDescription)"
        }
    }
}
