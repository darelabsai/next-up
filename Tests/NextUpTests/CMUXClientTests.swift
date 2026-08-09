import Foundation
import Testing
@testable import NextUp
@testable import NextUpCore

@Test func cmuxClientBoundsTopologyCommand() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("next-up-cmux-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("cmux")
    try "#!/bin/sh\nsleep 2\nprintf '{}'\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let started = Date()
    #expect(throws: BoundedProcessRunnerError.timedOut) {
        _ = try CMUXClient(executable: executable.path, commandDeadline: 0.05)
            .fetch(selection: WorkspaceSelection())
    }
    #expect(Date().timeIntervalSince(started) < 1)
}

@Test func cmuxClientCheapInventoryUsesOnlyTopologyCommand() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("next-up-cmux-inventory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("cmux")
    let log = directory.appendingPathComponent("arguments.log")
    let topology = #"{"windows":[{"workspaces":[{"ref":"workspace:1","id":"workspace-uuid","title":"Work","panes":[{"surfaces":[{"type":"terminal","ref":"surface:1","id":"surface-uuid","title":"⚠ Hermes"}]}]}]}]}"#
    let script = """
    #!/bin/sh
    printf '%s\n' "$*" >> "\(log.path)"
    printf '%s' '\(topology)'
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let inventory = try CMUXClient(executable: executable.path).fetchInventory()

    #expect(inventory.count == 1)
    #expect(inventory[0].lanes.map(\.title) == ["⚠ Hermes"])
    let invocations = try String(contentsOf: log, encoding: .utf8)
        .split(separator: "\n").map(String.init)
    #expect(invocations == ["--json --id-format both tree --all"])
    #expect(!invocations.contains { $0.contains("read-screen") || $0.contains("ssh-session") })
}

@Test func cmuxFullPollReportsInventoryAndReadFailureIdentity() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("next-up-cmux-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("cmux")
    let topology = #"{"windows":[{"workspaces":[{"ref":"workspace:1","id":"workspace-uuid","title":"Work","panes":[{"surfaces":[{"type":"terminal","ref":"surface:1","id":"surface-uuid","title":"⚠ Hermes"}]}]}]}]}"#
    let script = """
    #!/bin/sh
    if [ "$1" = "--json" ]; then
      printf '%s' '\(topology)'
      exit 0
    fi
    exit 1
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let result = try CMUXClient(executable: executable.path).fetch(selection: WorkspaceSelection())
    let identity = AttentionHintIdentity(
        workspacePersistentID: "workspace-uuid", workspaceRef: "workspace:1",
        surfacePersistentID: "surface-uuid", surfaceRef: "surface:1"
    )

    #expect(result.inventory.count == 1)
    #expect(result.readFailures == [identity])
    #expect(result.lanes.first?.state == .unknown)
}
