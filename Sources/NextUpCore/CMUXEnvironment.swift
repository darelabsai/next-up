import Foundation

public enum CMUXEnvironment {
    public static func applyingCapability(
        _ rawCapability: String,
        to base: [String: String]
    ) -> [String: String] {
        let capability = rawCapability.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !capability.isEmpty else { return base }
        var environment = base
        environment["CMUX_SOCKET_CAPABILITY"] = capability
        return environment
    }
}
