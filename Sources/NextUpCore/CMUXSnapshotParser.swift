import Foundation

public enum CMUXSnapshotParser {
    public static func parse(_ data: Data, workspace target: String) throws -> [LaneSnapshot] {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any],
              let windows = object["windows"] as? [[String: Any]] else {
            throw ParseError.invalidRoot
        }

        typealias WorkspaceMatch = (window: [String: Any], workspace: [String: Any])
        let matches: [WorkspaceMatch] = windows.flatMap { window -> [WorkspaceMatch] in
            let workspaces = (window["workspaces"] as? [[String: Any]]) ?? []
            return workspaces.compactMap { workspace -> WorkspaceMatch? in
                guard (workspace["ref"] as? String) == target ||
                        (workspace["title"] as? String) == target else { return nil }
                return (window: window, workspace: workspace)
            }
        }
        guard matches.count == 1 else {
            throw matches.isEmpty ? ParseError.workspaceNotFound(target) : ParseError.workspaceAmbiguous(target)
        }

        let window = matches[0].window
        let workspace = matches[0].workspace
        let panes = workspace["panes"] as? [[String: Any]] ?? []
        var lanes: [LaneSnapshot] = []
        for pane in panes {
            let surfaces = (pane["surfaces"] as? [[String: Any]]) ?? []
            for surface in surfaces {
                guard (surface["type"] as? String) == "terminal",
                      let id = surface["ref"] as? String,
                      let title = surface["title"] as? String else { continue }
                lanes.append(LaneSnapshot(
                    id: id,
                    persistentID: surface["id"] as? String,
                    title: title,
                    state: .unknown,
                    workspaceID: (workspace["ref"] as? String) ?? "",
                    workspacePersistentID: workspace["id"] as? String,
                    workspaceTitle: (workspace["title"] as? String) ?? "",
                    navigationTarget: CMUXNavigationTarget(
                        windowID: window["id"] as? String,
                        windowRef: window["ref"] as? String,
                        workspaceID: workspace["id"] as? String,
                        workspaceRef: workspace["ref"] as? String,
                        paneID: pane["id"] as? String,
                        paneRef: pane["ref"] as? String,
                        surfaceID: surface["id"] as? String,
                        surfaceRef: id
                    )
                ))
            }
        }
        return lanes.sorted { $0.id < $1.id }
    }

    public enum ParseError: Error, Equatable {
        case invalidRoot
        case workspaceNotFound(String)
        case workspaceAmbiguous(String)
    }
}
