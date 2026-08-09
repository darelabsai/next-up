import Foundation

public struct JarvisBridgeRequest: Equatable, Sendable {
    public let arguments: [String]
    public let standardInput: String?

    public init(arguments: [String], standardInput: String? = nil) {
        self.arguments = arguments
        self.standardInput = standardInput
    }

    public static func discovery(
        lane: LaneSnapshot,
        registryPath: String
    ) throws -> JarvisBridgeRequest {
        guard lane.persistentID != nil,
              lane.workspacePersistentID != nil else {
            throw JarvisBridgeRequestError.missingPersistentIdentity
        }
        guard let snippet = lane.matchingSnippet?.trimmingCharacters(in: .whitespacesAndNewlines),
              !snippet.isEmpty else {
            throw JarvisBridgeRequestError.missingMatchingSnippet
        }
        var arguments = commonArguments(
            command: "find", machine: lane.machine,
            profile: lane.hermesProfile, registryPath: registryPath
        )
        arguments += [
            "--title", LaneMonitorState.displayName(from: lane.title),
            "--candidate-limit", "10",
        ]
        arguments.append("--snippet-stdin")
        return JarvisBridgeRequest(
            arguments: arguments,
            standardInput: snippet
        )
    }

    public static func exactTurn(
        binding: HermesSessionBinding,
        registryPath: String
    ) -> JarvisBridgeRequest {
        var arguments = commonArguments(
            command: "get", machine: binding.machine,
            profile: binding.profile, registryPath: registryPath
        )
        arguments += ["--session-id", binding.sessionID]
        return JarvisBridgeRequest(arguments: arguments)
    }

    private static func commonArguments(
        command: String,
        machine: String,
        profile: String,
        registryPath: String
    ) -> [String] {
        [
            command,
            "--registry", registryPath,
            "--machine", machine,
            "--profile", profile,
            "--turns", "3",
            "--preview-chars", "6000",
            "--output-limit", "262144",
            "--timeout", "12",
            "--connect-timeout", "3",
            "--format", "json",
        ]
    }
}

public enum JarvisBridgeRequestError: Error, Equatable {
    case missingPersistentIdentity
    case missingMatchingSnippet
}
