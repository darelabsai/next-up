import Foundation
import Testing
@testable import NextUp
@testable import NextUpCore

private let completeActiveTopology = #"{"active":{"window_ref":"window:1","window_id":"WINDOW-UUID","workspace_ref":"workspace:1","workspace_id":"WORKSPACE-UUID","pane_ref":"pane:1","pane_id":"PANE-UUID","surface_ref":"surface:1","surface_id":"SURFACE-UUID"},"windows":[{"ref":"window:1","id":"WINDOW-UUID","workspaces":[{"ref":"workspace:1","id":"WORKSPACE-UUID","title":"Work","panes":[{"ref":"pane:1","id":"PANE-UUID","surfaces":[{"type":"terminal","ref":"surface:1","id":"SURFACE-UUID","title":"Hermes"}]}]}]}]}"#

private final class CMUXAcquisitionSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]
    private let output: Data
    private var dateCallCount = 0
    private(set) var invocations: [[String]] = []
    private(set) var runnerObservedDateCalls: Int?
    private(set) var observedDeadline: TimeInterval?

    init(dates: [Date], topology: String = completeActiveTopology) {
        self.dates = dates
        self.output = Data(topology.utf8)
    }

    func now() -> Date {
        lock.withLock {
            dateCallCount += 1
            return dates.removeFirst()
        }
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        deadline: TimeInterval
    ) throws -> BoundedProcessResult {
        lock.withLock {
            runnerObservedDateCalls = dateCallCount
            invocations.append(arguments)
            observedDeadline = deadline
        }
        return BoundedProcessResult(
            standardOutput: output,
            standardError: Data(),
            terminationStatus: 0
        )
    }
}

@Test func freshFocusAcquisitionUsesOneTopologyCommandAndStartsTimingBeforeLaunch() throws {
    let start = Date(timeIntervalSince1970: 100)
    let finish = start.addingTimeInterval(1.5)
    let spy = CMUXAcquisitionSpy(dates: [start, finish])
    let client = CMUXClient(
        now: spy.now,
        isCMUXFrontmost: { true },
        processRunner: spy.run
    )

    let acquisition = client.acquireFreshFocus()

    #expect(acquisition?.snapshot.records.count == 1)
    #expect(acquisition?.snapshot.activeFocus?.surfaceID == "SURFACE-UUID")
    #expect(acquisition?.isCMUXFrontmost == true)
    #expect(acquisition?.startedAt == start)
    #expect(acquisition?.finishedAt == finish)
    #expect(acquisition?.duration == 1.5)
    #expect(spy.runnerObservedDateCalls == 1)
    #expect(spy.invocations == [["--json", "--id-format", "both", "tree", "--all"]])
}

@Test func freshFocusAcquisitionRejectsActiveRouteMissingFromFinalInventory() {
    let mismatched = completeActiveTopology.replacingOccurrences(
        of: #""surface_id":"SURFACE-UUID""#,
        with: #""surface_id":"OTHER-SURFACE-UUID""#
    )
    let start = Date(timeIntervalSince1970: 100)
    let spy = CMUXAcquisitionSpy(
        dates: [start, start.addingTimeInterval(0.1)],
        topology: mismatched
    )
    let client = CMUXClient(
        now: spy.now,
        isCMUXFrontmost: { true },
        processRunner: spy.run
    )

    #expect(client.acquireFreshFocus() == nil)
    #expect(spy.invocations.count == 1)
}

@Test func freshFocusAcquisitionRejectsAmbiguousActiveRoute() {
    let duplicateSurface = #",{"type":"terminal","ref":"surface:1","id":"SURFACE-UUID","title":"Duplicate"}"#
    let ambiguous = completeActiveTopology.replacingOccurrences(
        of: #"{"type":"terminal","ref":"surface:1","id":"SURFACE-UUID","title":"Hermes"}"#,
        with: #"{"type":"terminal","ref":"surface:1","id":"SURFACE-UUID","title":"Hermes"}"# + duplicateSurface
    )
    let start = Date(timeIntervalSince1970: 100)
    let spy = CMUXAcquisitionSpy(
        dates: [start, start.addingTimeInterval(0.1)],
        topology: ambiguous
    )
    let client = CMUXClient(
        now: spy.now,
        isCMUXFrontmost: { true },
        processRunner: spy.run
    )

    #expect(client.acquireFreshFocus() == nil)
}

@Test func freshFocusAcquisitionAcceptsExactTwoSecondBoundary() {
    let start = Date(timeIntervalSince1970: 100)
    let spy = CMUXAcquisitionSpy(dates: [start, start.addingTimeInterval(2)])
    let client = CMUXClient(
        now: spy.now,
        isCMUXFrontmost: { true },
        processRunner: spy.run
    )

    #expect(client.acquireFreshFocus()?.duration == 2)
    #expect(spy.observedDeadline == 2)
}

@Test func freshFocusAcquisitionRejectsElapsedTimeOverTwoSeconds() {
    let start = Date(timeIntervalSince1970: 100)
    let spy = CMUXAcquisitionSpy(dates: [start, start.addingTimeInterval(2.001)])
    let client = CMUXClient(
        now: spy.now,
        isCMUXFrontmost: { true },
        processRunner: spy.run
    )

    #expect(client.acquireFreshFocus() == nil)
    #expect(spy.observedDeadline == 2)
}

@Test func freshFocusAcquisitionRejectsSlowTopologyCommand() {
    let client = CMUXClient(
        now: { Date(timeIntervalSince1970: 100) },
        isCMUXFrontmost: { true },
        processRunner: { _, _, _, deadline in
            #expect(deadline == 2)
            throw BoundedProcessRunnerError.timedOut
        }
    )

    #expect(client.acquireFreshFocus() == nil)
}

@Test func freshFocusAcquisitionRejectsWhenCMUXIsNotFrontmost() {
    let start = Date(timeIntervalSince1970: 100)
    let spy = CMUXAcquisitionSpy(dates: [start])
    let client = CMUXClient(
        now: spy.now,
        isCMUXFrontmost: { false },
        processRunner: spy.run
    )

    #expect(client.acquireFreshFocus() == nil)
    #expect(spy.invocations.count == 1)
}

@Test func freshFocusAcquisitionRejectsPartialActiveFocus() {
    let partial = completeActiveTopology.replacingOccurrences(
        of: #",\"surface_id\":\"SURFACE-UUID\""#.replacingOccurrences(of: "\\", with: ""),
        with: ""
    )
    let start = Date(timeIntervalSince1970: 100)
    let spy = CMUXAcquisitionSpy(dates: [start], topology: partial)
    let client = CMUXClient(
        now: spy.now,
        isCMUXFrontmost: { true },
        processRunner: spy.run
    )

    #expect(client.acquireFreshFocus() == nil)
}

@Test func freshFocusAcquisitionRejectsMissingActiveFocus() {
    let start = Date(timeIntervalSince1970: 100)
    let spy = CMUXAcquisitionSpy(dates: [start], topology: #"{"windows":[]}"#)
    let client = CMUXClient(
        now: spy.now,
        isCMUXFrontmost: { true },
        processRunner: spy.run
    )

    #expect(client.acquireFreshFocus() == nil)
}

@Test func freshFocusAcquisitionRejectsMalformedTopology() {
    let start = Date(timeIntervalSince1970: 100)
    let spy = CMUXAcquisitionSpy(dates: [start], topology: "not-json")
    let client = CMUXClient(
        now: spy.now,
        isCMUXFrontmost: { true },
        processRunner: spy.run
    )

    #expect(client.acquireFreshFocus() == nil)
}

@Test func freshFocusAcquisitionRejectsFailedTopologyCommand() {
    let client = CMUXClient(
        now: { Date(timeIntervalSince1970: 100) },
        isCMUXFrontmost: { true },
        processRunner: { _, _, _, _ in
            BoundedProcessResult(
                standardOutput: Data(completeActiveTopology.utf8),
                standardError: Data("failed".utf8),
                terminationStatus: 1
            )
        }
    )

    #expect(client.acquireFreshFocus() == nil)
}

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
