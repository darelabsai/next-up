import Foundation

public struct WorkspaceInfo: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let persistentID: String?
    public let title: String

    public init(id: String, persistentID: String? = nil, title: String) {
        self.id = id
        self.persistentID = persistentID
        self.title = title
    }
}

public struct WorkspaceInventoryRecord: Equatable, Sendable {
    public let info: WorkspaceInfo
    public let lanes: [LaneSnapshot]

    public init(info: WorkspaceInfo, lanes: [LaneSnapshot]) {
        self.info = info
        self.lanes = lanes
    }
}

public struct CMUXWorkspaceInventorySnapshot: Equatable, Sendable {
    public let records: [WorkspaceInventoryRecord]
    public let activeFocus: CMUXActiveFocus?

    public init(records: [WorkspaceInventoryRecord], activeFocus: CMUXActiveFocus?) {
        self.records = records
        self.activeFocus = activeFocus
    }
}

public enum CMUXWorkspaceInventoryParser {
    public static func parse(_ data: Data) throws -> [WorkspaceInventoryRecord] {
        try parseSnapshot(data).records
    }

    public static func parseSnapshot(_ data: Data) throws -> CMUXWorkspaceInventorySnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = root["windows"] as? [[String: Any]] else {
            throw ParseError.invalidRoot
        }

        let records = windows
            .flatMap { window -> [WorkspaceInventoryRecord] in
                let windowID = window["id"] as? String
                let windowRef = window["ref"] as? String
                let workspaces = window["workspaces"] as? [[String: Any]] ?? []
                return workspaces.compactMap { workspace -> WorkspaceInventoryRecord? in
                guard let workspaceID = workspace["ref"] as? String,
                      let workspaceTitle = workspace["title"] as? String else { return nil }
                let workspacePersistentID = workspace["id"] as? String
                let panes = workspace["panes"] as? [[String: Any]] ?? []
                let lanes = panes
                    .flatMap { pane -> [LaneSnapshot] in
                        let paneID = pane["id"] as? String
                        let paneRef = pane["ref"] as? String
                        let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                        return surfaces.compactMap { surface -> LaneSnapshot? in
                        guard (surface["type"] as? String) == "terminal",
                              let id = surface["ref"] as? String,
                              let title = surface["title"] as? String else { return nil }
                        let persistentID = surface["id"] as? String
                        return LaneSnapshot(
                            id: id,
                            persistentID: persistentID,
                            title: title,
                            state: .unknown,
                            workspaceID: workspaceID,
                            workspacePersistentID: workspacePersistentID,
                            workspaceTitle: workspaceTitle,
                            navigationTarget: CMUXNavigationTarget(
                                windowID: windowID,
                                windowRef: windowRef,
                                workspaceID: workspacePersistentID,
                                workspaceRef: workspaceID,
                                paneID: paneID,
                                paneRef: paneRef,
                                surfaceID: persistentID,
                                surfaceRef: id
                            )
                        )
                    }
                    }
                    .sorted { $0.id < $1.id }
                return WorkspaceInventoryRecord(
                    info: WorkspaceInfo(
                        id: workspaceID,
                        persistentID: workspacePersistentID,
                        title: workspaceTitle
                    ),
                    lanes: lanes
                )
            }
            }
            .sorted { $0.info.id < $1.info.id }

        return CMUXWorkspaceInventorySnapshot(
            records: records,
            activeFocus: parseActiveFocus(root["active"])
        )
    }

    private static func parseActiveFocus(_ value: Any?) -> CMUXActiveFocus? {
        guard let active = value as? [String: Any],
              let windowID = nonEmptyString(active["window_id"]),
              let windowRef = nonEmptyString(active["window_ref"]),
              let workspaceID = nonEmptyString(active["workspace_id"]),
              let workspaceRef = nonEmptyString(active["workspace_ref"]),
              let paneID = nonEmptyString(active["pane_id"]),
              let paneRef = nonEmptyString(active["pane_ref"]),
              let surfaceID = nonEmptyString(active["surface_id"]),
              let surfaceRef = nonEmptyString(active["surface_ref"]) else {
            return nil
        }

        return CMUXActiveFocus(
            windowID: windowID,
            windowRef: windowRef,
            workspaceID: workspaceID,
            workspaceRef: workspaceRef,
            paneID: paneID,
            paneRef: paneRef,
            surfaceID: surfaceID,
            surfaceRef: surfaceRef
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    public enum ParseError: Error, Equatable {
        case invalidRoot
    }
}
