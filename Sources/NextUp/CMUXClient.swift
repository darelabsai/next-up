import Foundation
import NextUpCore

struct CMUXPollResult: Sendable {
    let workspaces: [WorkspaceInfo]
    let inventory: [WorkspaceInventoryRecord]
    let lanes: [LaneSnapshot]
    let readFailures: Set<AttentionHintIdentity>
    let quarantinedLaneIDs: Set<String>

    init(
        workspaces: [WorkspaceInfo],
        inventory: [WorkspaceInventoryRecord],
        lanes: [LaneSnapshot],
        readFailures: Set<AttentionHintIdentity>,
        quarantinedLaneIDs: Set<String> = []
    ) {
        self.workspaces = workspaces
        self.inventory = inventory
        self.lanes = lanes
        self.readFailures = readFailures
        self.quarantinedLaneIDs = quarantinedLaneIDs
    }
}

struct CMUXClient: Sendable {
    let executable: String
    let commandDeadline: TimeInterval

    init(
        executable: String = "/Applications/cmux.app/Contents/Resources/bin/cmux",
        commandDeadline: TimeInterval = 3
    ) {
        self.executable = executable
        self.commandDeadline = commandDeadline
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

    private func run(_ arguments: [String]) throws -> Data {
        let result = try BoundedProcessRunner().run(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: Self.childEnvironment(),
            deadline: commandDeadline
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
