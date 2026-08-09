public struct CMUXActiveFocus: Equatable, Sendable {
    public let windowID: String?
    public let windowRef: String?
    public let workspaceID: String?
    public let workspaceRef: String?
    public let paneID: String?
    public let paneRef: String?
    public let surfaceID: String?
    public let surfaceRef: String?

    public init(
        windowID: String? = nil,
        windowRef: String? = nil,
        workspaceID: String? = nil,
        workspaceRef: String? = nil,
        paneID: String? = nil,
        paneRef: String? = nil,
        surfaceID: String? = nil,
        surfaceRef: String? = nil
    ) {
        self.windowID = Self.nonEmpty(windowID)
        self.windowRef = Self.nonEmpty(windowRef)
        self.workspaceID = Self.nonEmpty(workspaceID)
        self.workspaceRef = Self.nonEmpty(workspaceRef)
        self.paneID = Self.nonEmpty(paneID)
        self.paneRef = Self.nonEmpty(paneRef)
        self.surfaceID = Self.nonEmpty(surfaceID)
        self.surfaceRef = Self.nonEmpty(surfaceRef)
    }

    public func exactlyMatches(_ target: CMUXNavigationTarget) -> Bool {
        guard let windowID, let workspaceID, let paneID, let surfaceID,
              let targetWindowID = target.windowID,
              let targetWorkspaceID = target.workspaceID,
              let targetPaneID = target.paneID,
              let targetSurfaceID = target.surfaceID else {
            return false
        }

        return windowID == targetWindowID &&
            workspaceID == targetWorkspaceID &&
            paneID == targetPaneID &&
            surfaceID == targetSurfaceID
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
