import Foundation
import AppKit
import NextUpCore

struct CMUXFreshFocusAcquisition: Sendable {
    let snapshot: CMUXWorkspaceInventorySnapshot
    let isCMUXFrontmost: Bool
    let startedAt: Date
    let finishedAt: Date

    var duration: TimeInterval {
        finishedAt.timeIntervalSince(startedAt)
    }
}

struct CMUXPollResult: Sendable {
    let workspaces: [WorkspaceInfo]
    let inventory: [WorkspaceInventoryRecord]
    let lanes: [LaneSnapshot]
    let readFailures: Set<AttentionHintIdentity>
    let quarantinedLaneIDs: Set<String>
    let pollKind: WatcherPollKind
    let focusEligibility: [FocusAlertIdentity]
    let focusObservation: CMUXFreshFocusAcquisition?
    let preEnrichmentFocusPlan: FocusSuppressionPlan

    init(
        workspaces: [WorkspaceInfo],
        inventory: [WorkspaceInventoryRecord],
        lanes: [LaneSnapshot],
        readFailures: Set<AttentionHintIdentity>,
        quarantinedLaneIDs: Set<String> = [],
        pollKind: WatcherPollKind = .baseline,
        focusEligibility: [FocusAlertIdentity] = [],
        focusObservation: CMUXFreshFocusAcquisition? = nil,
        preEnrichmentFocusPlan: FocusSuppressionPlan = .empty
    ) {
        self.workspaces = workspaces
        self.inventory = inventory
        self.lanes = lanes
        self.readFailures = readFailures
        self.quarantinedLaneIDs = quarantinedLaneIDs
        self.pollKind = pollKind
        self.focusEligibility = focusEligibility
        self.focusObservation = focusObservation
        self.preEnrichmentFocusPlan = preEnrichmentFocusPlan
    }

    func carrying(
        pollKind: WatcherPollKind,
        focusEligibility: [FocusAlertIdentity],
        focusObservation: CMUXFreshFocusAcquisition?
    ) -> CMUXPollResult {
        CMUXPollResult(
            workspaces: workspaces,
            inventory: inventory,
            lanes: lanes,
            readFailures: readFailures,
            quarantinedLaneIDs: quarantinedLaneIDs,
            pollKind: pollKind,
            focusEligibility: focusEligibility,
            focusObservation: focusObservation,
            preEnrichmentFocusPlan: preEnrichmentFocusPlan
        )
    }

    func carrying(preEnrichmentFocusPlan: FocusSuppressionPlan) -> CMUXPollResult {
        CMUXPollResult(
            workspaces: workspaces,
            inventory: inventory,
            lanes: lanes,
            readFailures: readFailures,
            quarantinedLaneIDs: quarantinedLaneIDs,
            pollKind: pollKind,
            focusEligibility: focusEligibility,
            focusObservation: focusObservation,
            preEnrichmentFocusPlan: preEnrichmentFocusPlan
        )
    }
}

struct CMUXClient: Sendable {
    typealias ProcessRunner = @Sendable (
        _ executableURL: URL,
        _ arguments: [String],
        _ environment: [String: String]?,
        _ deadline: TimeInterval
    ) throws -> BoundedProcessResult

    let executable: String
    let commandDeadline: TimeInterval
    private let now: @Sendable () -> Date
    private let isCMUXFrontmost: @Sendable () -> Bool
    private let processRunner: ProcessRunner

    init(
        executable: String = "/Applications/cmux.app/Contents/Resources/bin/cmux",
        commandDeadline: TimeInterval = 3,
        now: @escaping @Sendable () -> Date = Date.init,
        isCMUXFrontmost: @escaping @Sendable () -> Bool = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.cmuxterm.app"
        },
        processRunner: @escaping ProcessRunner = { executableURL, arguments, environment, deadline in
            try BoundedProcessRunner().run(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                deadline: deadline
            )
        }
    ) {
        self.executable = executable
        self.commandDeadline = commandDeadline
        self.now = now
        self.isCMUXFrontmost = isCMUXFrontmost
        self.processRunner = processRunner
    }

    func acquireFreshFocus() -> CMUXFreshFocusAcquisition? {
        let arguments = ["--json", "--id-format", "both", "tree", "--all"]
        let environment = Self.childEnvironment()
        let startedAt = now()
        guard let result = try? processRunner(
            URL(fileURLWithPath: executable),
            arguments,
            environment,
            min(commandDeadline, 2)
        ), result.terminationStatus == 0,
           let snapshot = try? CMUXWorkspaceInventoryParser.parseSnapshot(result.standardOutput),
           let activeFocus = snapshot.activeFocus,
           Self.activeRouteMatchCount(activeFocus, in: snapshot) == 1,
           isCMUXFrontmost() else {
            return nil
        }
        let finishedAt = now()
        let duration = finishedAt.timeIntervalSince(startedAt)
        guard duration >= 0, duration <= 2 else { return nil }
        return CMUXFreshFocusAcquisition(
            snapshot: snapshot,
            isCMUXFrontmost: true,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    private static func activeRouteMatchCount(
        _ focus: CMUXActiveFocus,
        in snapshot: CMUXWorkspaceInventorySnapshot
    ) -> Int {
        let activeTarget = CMUXNavigationTarget(
            windowID: focus.windowID,
            windowRef: focus.windowRef,
            workspaceID: focus.workspaceID,
            workspaceRef: focus.workspaceRef,
            paneID: focus.paneID,
            paneRef: focus.paneRef,
            surfaceID: focus.surfaceID,
            surfaceRef: focus.surfaceRef
        )
        return snapshot.records.reduce(into: 0) { count, record in
            count += record.lanes.count { $0.navigationTarget == activeTarget }
        }
    }

    func fetchInventory() throws -> [WorkspaceInventoryRecord] {
        let topologyData = try run(["--json", "--id-format", "both", "tree", "--all"])
        return try CMUXWorkspaceInventoryParser.parse(topologyData)
    }

    func fetch(selection: WorkspaceSelection) throws -> CMUXPollResult {
        let inventory = try fetchInventory()
        let sshInventory: String?
        if let data = try? run(["ssh-session-list", "--all-workspaces"]) {
            sshInventory = String(data: data, encoding: .utf8) ?? ""
        } else {
            sshInventory = nil
        }
        var monitoredLanes: [LaneSnapshot] = []
        var readFailures: Set<AttentionHintIdentity> = []

        for workspace in inventory where selection.isSelected(workspace.info.id) {
            for lane in workspace.lanes {
                let machine = sshInventory.map {
                    CMUXSSHSessionIndex.machine(for: lane, inventory: $0)
                } ?? "unresolved"
                guard let screenData = try? run([
                    "read-screen", "--workspace", workspace.info.id,
                    "--surface", lane.id, "--lines", "80",
                ]), let screen = String(data: screenData, encoding: .utf8) else {
                    readFailures.insert(AttentionHintIdentity(
                        workspacePersistentID: workspace.info.persistentID,
                        workspaceRef: workspace.info.id,
                        surfacePersistentID: lane.persistentID,
                        surfaceRef: lane.id
                    ))
                    monitoredLanes.append(LaneSnapshot(
                        id: lane.id,
                        persistentID: lane.persistentID,
                        title: lane.title,
                        state: .unknown,
                        workspaceID: workspace.info.id,
                        workspacePersistentID: workspace.info.persistentID,
                        workspaceTitle: workspace.info.title,
                        machine: machine,
                        navigationTarget: lane.navigationTarget
                    ))
                    continue
                }
                monitoredLanes.append(LaneScreenSnapshotBuilder.build(
                    id: lane.id,
                    persistentID: lane.persistentID,
                    title: lane.title,
                    workspaceID: workspace.info.id,
                    workspacePersistentID: workspace.info.persistentID,
                    workspaceTitle: workspace.info.title,
                    machine: machine,
                    navigationTarget: lane.navigationTarget,
                    screen: screen
                ))
            }
        }

        return CMUXPollResult(
            workspaces: inventory.map(\.info),
            inventory: inventory,
            lanes: monitoredLanes,
            readFailures: readFailures
        )
    }

    private func run(_ arguments: [String], deadline: TimeInterval? = nil) throws -> Data {
        let result = try processRunner(
            URL(fileURLWithPath: executable),
            arguments,
            Self.childEnvironment(),
            deadline ?? commandDeadline
        )
        guard result.terminationStatus == 0 else {
            let message = String(data: result.standardError, encoding: .utf8) ?? "unknown CMUX error"
            throw ClientError.cmuxFailed(result.terminationStatus, message)
        }
        return result.standardOutput
    }

    static func childEnvironment() -> [String: String] {
        let capabilityURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("NextUp", isDirectory: true)
            .appendingPathComponent("cmux-capability")
        guard let capability = try? String(contentsOf: capabilityURL, encoding: .utf8) else {
            return ProcessInfo.processInfo.environment
        }
        return CMUXEnvironment.applyingCapability(
            capability,
            to: ProcessInfo.processInfo.environment
        )
    }

    enum ClientError: LocalizedError {
        case cmuxFailed(Int32, String)

        var errorDescription: String? {
            switch self {
            case let .cmuxFailed(status, message):
                return "CMUX exited \(status): \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }
}
