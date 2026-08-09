import Foundation

public struct WorkspaceSelection: Codable, Equatable, Sendable {
    public private(set) var excludedWorkspaceIDs: Set<String>

    public init(excludedWorkspaceIDs: Set<String> = []) {
        self.excludedWorkspaceIDs = excludedWorkspaceIDs
    }

    public func isSelected(_ workspaceID: String) -> Bool {
        !excludedWorkspaceIDs.contains(workspaceID)
    }

    public mutating func toggle(_ workspaceID: String) {
        if excludedWorkspaceIDs.contains(workspaceID) {
            excludedWorkspaceIDs.remove(workspaceID)
        } else {
            excludedWorkspaceIDs.insert(workspaceID)
        }
    }

    public mutating func selectAll() {
        excludedWorkspaceIDs.removeAll()
    }
}
