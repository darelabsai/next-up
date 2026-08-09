import Foundation
import Testing
@testable import NextUp
@testable import NextUpCore

@Test func jarvisBridgeFailsClosedWhenValidJSONExceedsParentOutputLimit() throws {
    let executable = try makeJarvisHelper(body: """
    import json, sys
    envelope = {"schema_version":"1.0","provenance":{"machine":"local","hermes_profile":"default"},"match":{"status":"not_matched","method":"none"},"session":None,"turns":[]}
    sys.stdout.write(json.dumps(envelope) + (' ' * 300000))
    """)
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

    do {
        _ = try JarvisBridgeClient(executableURL: executable, registryPath: "/tmp/registry.json")
            .discover(lane: discoveryLane())
        Issue.record("Expected oversized output to fail closed")
    } catch JarvisBridgeClientError.invalidResponse {
        // Expected.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func jarvisBridgePreservesArgumentsAndStdin() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("next-up-jarvis-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let argumentsFile = directory.appendingPathComponent("arguments.json")
    let stdinFile = directory.appendingPathComponent("stdin.txt")
    let executable = try makeJarvisHelper(in: directory, body: """
    import json, sys
    open(\(String(reflecting: argumentsFile.path)), 'w').write(json.dumps(sys.argv[1:]))
    open(\(String(reflecting: stdinFile.path)), 'w').write(sys.stdin.read())
    print(json.dumps({"schema_version":"1.0","provenance":{"machine":"local","hermes_profile":"default"},"match":{"status":"not_matched","method":"none"},"session":None,"turns":[]}))
    """)

    let client = JarvisBridgeClient(executableURL: executable, registryPath: "/tmp/registry exact.json")
    _ = try client.discover(lane: discoveryLane())

    let arguments = try JSONDecoder().decode(
        [String].self, from: Data(contentsOf: argumentsFile)
    )
    let expected = try JarvisBridgeRequest.discovery(
        lane: discoveryLane(), registryPath: "/tmp/registry exact.json"
    )
    #expect(arguments == expected.arguments)
    #expect(try String(contentsOf: stdinFile, encoding: .utf8) == expected.standardInput)
}

@Test func jarvisBridgeBoundsReportedStandardError() throws {
    let executable = try makeJarvisHelper(body: """
    import sys
    sys.stderr.write('e' * 100000)
    sys.exit(7)
    """)
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

    do {
        _ = try JarvisBridgeClient(executableURL: executable, registryPath: "/tmp/registry.json")
            .discover(lane: discoveryLane())
        Issue.record("Expected helper failure")
    } catch let JarvisBridgeClientError.failed(status, message) {
        #expect(status == 7)
        #expect(message == String(repeating: "e", count: 2_000))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func discoveryLane() -> LaneSnapshot {
    LaneSnapshot(
        id: "surface:1", persistentID: "surface-uuid", title: "Hermes",
        state: .ready, matchingSnippet: "exact snippet\nwith newline",
        workspacePersistentID: "workspace-uuid", machine: "local",
        hermesProfile: "default"
    )
}

private func makeJarvisHelper(body: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("next-up-jarvis-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try makeJarvisHelper(in: directory, body: body)
}

private func makeJarvisHelper(in directory: URL, body: String) throws -> URL {
    let executable = directory.appendingPathComponent("jarvis-helper")
    try ("#!/usr/bin/python3\n" + body + "\n").write(
        to: executable, atomically: true, encoding: .utf8
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: executable.path
    )
    return executable
}