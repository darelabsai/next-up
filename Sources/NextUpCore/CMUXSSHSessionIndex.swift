import Foundation

public enum CMUXSSHSessionIndex {
    /// Routes only an exact retained-SSH identity to the Mac Mini. Anything
    /// incomplete or unmatched stays local rather than guessing a remote host.
    public static func machine(for lane: LaneSnapshot, inventory: String) -> String {
        guard let workspaceID = lane.workspacePersistentID, !workspaceID.isEmpty,
              let surfaceID = lane.persistentID, !surfaceID.isEmpty else {
            return "mac-air"
        }
        let retainedSessionID = "ssh-\(workspaceID)-\(surfaceID)"
        let hasExactIdentity = inventory.split(separator: "\n").contains { line in
            line.split(whereSeparator: \.isWhitespace).contains { field in
                field == retainedSessionID
            }
        }
        return hasExactIdentity ? "mac-mini" : "mac-air"
    }
}
