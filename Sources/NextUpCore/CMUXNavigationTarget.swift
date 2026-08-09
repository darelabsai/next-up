import Foundation

public struct CMUXNavigationTarget: Codable, Equatable, Sendable {
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

    public init?(userInfo: [String: String]) {
        self.init(
            windowID: userInfo[Key.windowID],
            windowRef: userInfo[Key.windowRef],
            workspaceID: userInfo[Key.workspaceID],
            workspaceRef: userInfo[Key.workspaceRef],
            paneID: userInfo[Key.paneID],
            paneRef: userInfo[Key.paneRef],
            surfaceID: userInfo[Key.surfaceID],
            surfaceRef: userInfo[Key.surfaceRef]
        )
        guard !self.userInfo.isEmpty else { return nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            windowID: try container.decodeIfPresent(String.self, forKey: .windowID),
            windowRef: try container.decodeIfPresent(String.self, forKey: .windowRef),
            workspaceID: try container.decodeIfPresent(String.self, forKey: .workspaceID),
            workspaceRef: try container.decodeIfPresent(String.self, forKey: .workspaceRef),
            paneID: try container.decodeIfPresent(String.self, forKey: .paneID),
            paneRef: try container.decodeIfPresent(String.self, forKey: .paneRef),
            surfaceID: try container.decodeIfPresent(String.self, forKey: .surfaceID),
            surfaceRef: try container.decodeIfPresent(String.self, forKey: .surfaceRef)
        )
        guard !userInfo.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "empty CMUX route")
            )
        }
    }

    public var userInfo: [String: String] {
        var values: [String: String] = [:]
        values.set(windowID, for: Key.windowID)
        values.set(windowRef, for: Key.windowRef)
        values.set(workspaceID, for: Key.workspaceID)
        values.set(workspaceRef, for: Key.workspaceRef)
        values.set(paneID, for: Key.paneID)
        values.set(paneRef, for: Key.paneRef)
        values.set(surfaceID, for: Key.surfaceID)
        values.set(surfaceRef, for: Key.surfaceRef)
        return values
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case windowID, windowRef, workspaceID, workspaceRef
        case paneID, paneRef, surfaceID, surfaceRef
    }

    private enum Key {
        static let windowID = "cmuxWindowID"
        static let windowRef = "cmuxWindowRef"
        static let workspaceID = "cmuxWorkspaceID"
        static let workspaceRef = "cmuxWorkspaceRef"
        static let paneID = "cmuxPaneID"
        static let paneRef = "cmuxPaneRef"
        static let surfaceID = "cmuxSurfaceID"
        static let surfaceRef = "cmuxSurfaceRef"
    }
}

private extension Dictionary where Key == String, Value == String {
    mutating func set(_ value: String?, for key: String) {
        if let value { self[key] = value }
    }
}
