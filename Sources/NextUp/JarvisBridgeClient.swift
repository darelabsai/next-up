import Foundation
import NextUpCore

protocol HermesSessionBridgeClient: Sendable {
    func discover(
        lane: LaneSnapshot,
        now: Date
    ) throws -> (HermesSessionBinding, HermesFinalTurn?)?
    func latestTurn(binding: HermesSessionBinding) throws -> HermesFinalTurn?
}

struct JarvisBridgeClient: HermesSessionBridgeClient, Sendable {
    let executableURL: URL
    let registryPath: String

    init(
        executableURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/jarvis-bridge"),
        registryPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("dev/jarvis-bridge/config/machines.json").path
    ) {
        self.executableURL = executableURL
        self.registryPath = registryPath
    }

    func discover(lane: LaneSnapshot, now: Date = Date()) throws -> (HermesSessionBinding, HermesFinalTurn?)? {
        let request = try JarvisBridgeRequest.discovery(lane: lane, registryPath: registryPath)
        let envelope = try execute(request)
        guard let binding = envelope.binding(for: lane, resolvedAt: now) else { return nil }
        return (binding, envelope.latestCompleteTurn)
    }

    func latestTurn(binding: HermesSessionBinding) throws -> HermesFinalTurn? {
        let request = JarvisBridgeRequest.exactTurn(binding: binding, registryPath: registryPath)
        let envelope = try execute(request)
        guard envelope.schemaVersion == "1.0",
              envelope.match.status == "matched",
              envelope.session?.id == binding.sessionID,
              envelope.provenance.machine == binding.machine,
              envelope.provenance.hermesProfile == binding.profile else {
            throw JarvisBridgeClientError.provenanceMismatch
        }
        return envelope.latestCompleteTurn
    }

    private func execute(_ request: JarvisBridgeRequest) throws -> JarvisBridgeEnvelope {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw JarvisBridgeClientError.executableUnavailable
        }
        let result: BoundedProcessResult
        do {
            result = try BoundedProcessRunner().run(
                executableURL: executableURL,
                arguments: request.arguments,
                standardInput: request.standardInput.map { Data($0.utf8) } ?? Data(),
                deadline: 20,
                standardOutputLimit: 262_144
            )
        } catch BoundedProcessRunnerError.standardOutputExceededLimit {
            throw JarvisBridgeClientError.invalidResponse
        } catch BoundedProcessRunnerError.timedOut {
            throw JarvisBridgeClientError.timedOut
        } catch BoundedProcessRunnerError.outputDrainTimedOut {
            throw JarvisBridgeClientError.timedOut
        }
        guard result.terminationStatus == 0 else {
            let message = String(decoding: result.standardError.prefix(2_000), as: UTF8.self)
            throw JarvisBridgeClientError.failed(status: result.terminationStatus, message: message)
        }
        do {
            return try JSONDecoder().decode(JarvisBridgeEnvelope.self, from: result.standardOutput)
        } catch {
            throw JarvisBridgeClientError.invalidResponse
        }
    }
}

enum JarvisBridgeClientError: LocalizedError {
    case executableUnavailable
    case timedOut
    case failed(status: Int32, message: String)
    case invalidResponse
    case provenanceMismatch

    var errorDescription: String? {
        switch self {
        case .executableUnavailable: return "Jarvis Bridge executable is unavailable"
        case .timedOut: return "Jarvis Bridge request timed out"
        case let .failed(status, message): return "Jarvis Bridge exited \(status): \(message)"
        case .invalidResponse: return "Jarvis Bridge returned invalid JSON"
        case .provenanceMismatch: return "Jarvis Bridge provenance did not match the cached binding"
        }
    }
}
