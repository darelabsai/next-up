import Foundation

public struct HermesSessionBinding: Codable, Equatable, Sendable {
    public let surfacePersistentID: String
    public let workspacePersistentID: String
    public let machine: String
    public let profile: String
    public let sessionID: String
    public let matchMethod: String
    public let resolvedAt: Date

    public init(
        surfacePersistentID: String,
        workspacePersistentID: String,
        machine: String,
        profile: String,
        sessionID: String,
        matchMethod: String,
        resolvedAt: Date
    ) {
        self.surfacePersistentID = surfacePersistentID
        self.workspacePersistentID = workspacePersistentID
        self.machine = machine
        self.profile = profile
        self.sessionID = sessionID
        self.matchMethod = matchMethod
        self.resolvedAt = resolvedAt
    }
}

public struct HermesSessionBindingCache: Codable, Equatable, Sendable {
    public private(set) var bindings: [String: HermesSessionBinding]

    public init(bindings: [String: HermesSessionBinding] = [:]) {
        self.bindings = bindings
    }

    public func binding(for lane: LaneSnapshot) -> HermesSessionBinding? {
        guard let surfaceID = lane.persistentID,
              let workspaceID = lane.workspacePersistentID,
              let binding = bindings[surfaceID],
              binding.surfacePersistentID == surfaceID,
              binding.workspacePersistentID == workspaceID,
              binding.machine == lane.machine,
              binding.profile == lane.hermesProfile else {
            return nil
        }
        return binding
    }

    public mutating func remember(_ binding: HermesSessionBinding) {
        bindings[binding.surfacePersistentID] = binding
    }

    public mutating func invalidate(surfacePersistentID: String) {
        bindings.removeValue(forKey: surfacePersistentID)
    }

    public mutating func retain(surfacePersistentIDs: Set<String>) {
        bindings = bindings.filter { surfacePersistentIDs.contains($0.key) }
    }
}

public struct HermesFinalTurn: Equatable, Sendable {
    public let userText: String
    public let assistantText: String
    public let toolNames: [String]
    public let lastMessageID: Int
}

public struct JarvisBridgeEnvelope: Decodable, Sendable {
    public struct Provenance: Decodable, Sendable {
        public let machine: String
        public let hermesProfile: String

        enum CodingKeys: String, CodingKey {
            case machine
            case hermesProfile = "hermes_profile"
        }
    }

    public struct Match: Decodable, Sendable {
        public let status: String
        public let method: String
    }

    public struct Session: Decodable, Sendable {
        public let id: String
        public let title: String?
    }

    public struct Content: Decodable, Sendable {
        public let preview: String
        public let truncated: Bool
    }

    public struct Event: Decodable, Sendable {
        public let messageID: Int
        public let type: String
        public let content: Content?
        public let name: String?

        enum CodingKeys: String, CodingKey {
            case messageID = "message_id"
            case type, content, name
        }
    }

    public struct Turn: Decodable, Sendable {
        public let state: String
        public let firstMessageID: Int
        public let lastMessageID: Int
        public let events: [Event]

        enum CodingKeys: String, CodingKey {
            case state, events
            case firstMessageID = "first_message_id"
            case lastMessageID = "last_message_id"
        }
    }

    public let schemaVersion: String
    public let provenance: Provenance
    public let match: Match
    public let session: Session?
    public let turns: [Turn]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case provenance, match, session, turns
    }

    public func binding(for lane: LaneSnapshot, resolvedAt: Date) -> HermesSessionBinding? {
        guard schemaVersion == "1.0",
              match.status == "matched",
              provenance.machine == lane.machine,
              provenance.hermesProfile == lane.hermesProfile,
              let surfaceID = lane.persistentID,
              let workspaceID = lane.workspacePersistentID,
              let session, !session.id.isEmpty else {
            return nil
        }
        return HermesSessionBinding(
            surfacePersistentID: surfaceID,
            workspacePersistentID: workspaceID,
            machine: lane.machine,
            profile: lane.hermesProfile,
            sessionID: session.id,
            matchMethod: match.method,
            resolvedAt: resolvedAt
        )
    }

    public var latestCompleteTurn: HermesFinalTurn? {
        guard let turn = turns.last(where: { $0.state == "complete" }),
              let user = turn.events.first(where: { $0.type == "user" })?.content?.preview,
              let assistant = turn.events.last(where: { $0.type == "assistant" })?.content?.preview,
              !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        var seen = Set<String>()
        let tools = turn.events.compactMap { event -> String? in
            guard event.type == "tool_result", let name = event.name, !name.isEmpty,
                  seen.insert(name).inserted else { return nil }
            return name
        }
        return HermesFinalTurn(
            userText: user,
            assistantText: assistant,
            toolNames: tools,
            lastMessageID: turn.lastMessageID
        )
    }
}
