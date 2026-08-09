import Foundation
import Testing
@testable import NextUp
@testable import NextUpCore

private final class NavigationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [[String]] = []
    private var storedActivations = 0
    private var storedEvents: [String] = []

    var calls: [[String]] { lock.withLock { storedCalls } }
    var activations: Int { lock.withLock { storedActivations } }
    var events: [String] { lock.withLock { storedEvents } }

    func append(_ arguments: [String]) {
        lock.withLock {
            storedCalls.append(arguments)
            storedEvents.append(arguments.first ?? "empty-command")
        }
    }

    func activate() -> Bool {
        lock.withLock {
            storedActivations += 1
            storedEvents.append("activate-app")
        }
        return true
    }
}

private func topology(
    windowID: String? = "W",
    windowRef: String = "window:1",
    workspaceID: String? = "WS",
    workspaceRef: String = "workspace:1",
    paneID: String? = "P",
    paneRef: String = "pane:1",
    surfaceID: String? = "S",
    surfaceRef: String = "surface:1"
) -> Data {
    func field(_ name: String, _ value: String?) -> String {
        value.map { "\"\(name)\":\"\($0)\"," } ?? ""
    }
    let json = """
    {"windows":[{
      \(field("id", windowID))"ref":"\(windowRef)","workspaces":[{
        \(field("id", workspaceID))"ref":"\(workspaceRef)","title":"PRIVATE WORKSPACE","panes":[{
          \(field("id", paneID))"ref":"\(paneRef)","surfaces":[{
            \(field("id", surfaceID))"ref":"\(surfaceRef)","type":"terminal","title":"PRIVATE SURFACE"
          }]
        }]
      }]
    }]}
    """
    return Data(json.utf8)
}

private func executor(
    topologyData: Data,
    failingCommand: String? = nil,
    recorder: NavigationRecorder = NavigationRecorder(),
    topologyDelay: TimeInterval = 0
) -> (CMUXNavigationExecutor, NavigationRecorder) {
    let command: @Sendable ([String]) throws -> CMUXNavigationCommandResult = { arguments in
        recorder.append(arguments)
        if arguments.first == "--json" {
            if topologyDelay > 0 { Thread.sleep(forTimeInterval: topologyDelay) }
            return CMUXNavigationCommandResult(status: 0, output: topologyData)
        }
        let rendered = arguments.joined(separator: " ")
        let shouldFail = failingCommand == "*" || failingCommand.map(rendered.contains) == true
        return CMUXNavigationCommandResult(
            status: shouldFail ? 9 : 0,
            output: Data()
        )
    }
    return (CMUXNavigationExecutor(command: command), recorder)
}

private let completeTarget = CMUXNavigationTarget(
    windowID: "W", windowRef: "window:1",
    workspaceID: "WS", workspaceRef: "workspace:1",
    paneID: "P", paneRef: "pane:1",
    surfaceID: "S", surfaceRef: "surface:1"
)

@Test func completePersistentRouteUsesValidatedFreshRefsForScopedChildFocus() async {
    let (routeExecutor, recorder) = executor(topologyData: topology())
    let navigator = CMUXNotificationNavigator(
        executor: routeExecutor,
        appActivator: CMUXAppActivator(activate: recorder.activate)
    )

    let result = await navigator.navigate(to: completeTarget)

    #expect(result.deepestSuccess == .surface)
    #expect(recorder.calls == [
        ["--json", "--id-format", "both", "tree", "--all"],
        ["focus-window", "--window", "W"],
        ["select-workspace", "--workspace", "WS"],
        ["focus-panel", "--panel", "surface:1", "--workspace", "WS", "--window", "W"],
    ])
    #expect(recorder.calls.flatMap { $0 }.contains("PRIVATE SURFACE") == false)
    #expect(recorder.activations == 1)
}

@Test func failedWindowDoesNotBlockGloballyVerifiedPersistentChildren() {
    let (navigator, recorder) = executor(topologyData: topology(), failingCommand: "focus-window")

    let result = navigator.navigate(to: completeTarget)

    #expect(result.deepestSuccess == .surface)
    #expect(recorder.calls.contains(["select-workspace", "--workspace", "WS"]))
    #expect(recorder.calls.contains([
        "focus-panel", "--panel", "surface:1", "--workspace", "WS", "--window", "W",
    ]))
}

@Test func missingPersistentSurfaceNeverFallsBackToReusedCapturedRef() {
    let current = topology(surfaceID: "OTHER", surfaceRef: "surface:1")
    let (navigator, recorder) = executor(topologyData: current)

    let result = navigator.navigate(to: completeTarget)

    #expect(result.deepestSuccess == .pane)
    #expect(!recorder.calls.contains { $0.first == "focus-panel" })
    #expect(recorder.calls.contains([
        "focus-pane", "--pane", "pane:1", "--workspace", "WS", "--window", "W",
    ]))
}

@Test func refOnlySurfaceFailsClosedWhenCapturedPersistentPaneIsMissing() {
    let reusedTopology = topology(
        windowID: "window-uuid", windowRef: "window:1",
        workspaceID: "workspace-uuid", workspaceRef: "workspace:2",
        paneID: "replacement-pane-uuid", paneRef: "pane:replacement",
        surfaceID: nil, surfaceRef: "surface:4"
    )
    let (navigator, recorder) = executor(topologyData: reusedTopology)
    let target = CMUXNavigationTarget(
        windowID: "window-uuid", windowRef: "window:1",
        workspaceID: "workspace-uuid", workspaceRef: "workspace:2",
        paneID: "missing-original-pane-uuid", paneRef: "pane:original",
        surfaceRef: "surface:4"
    )

    let result = navigator.navigate(to: target)

    #expect(result.deepestSuccess == .workspace)
    #expect(!recorder.calls.contains { $0.first == "focus-panel" })
    #expect(!recorder.calls.contains { $0.first == "focus-pane" })
}

@Test func refOnlyHierarchyUsesEveryRequiredPersistentScope() {
    let current = topology(workspaceID: nil, paneID: nil, surfaceID: nil)
    let target = CMUXNavigationTarget(
        windowID: "W", windowRef: "window:1",
        workspaceRef: "workspace:1", paneRef: "pane:1", surfaceRef: "surface:1"
    )
    let (navigator, recorder) = executor(topologyData: current)

    let result = navigator.navigate(to: target)

    #expect(result.deepestSuccess == .surface)
    #expect(recorder.calls == [
        ["--json", "--id-format", "both", "tree", "--all"],
        ["focus-window", "--window", "W"],
        ["select-workspace", "--workspace", "workspace:1", "--window", "W"],
        ["focus-panel", "--panel", "surface:1", "--workspace", "workspace:1", "--window", "W"],
    ])
}

@Test func surfaceFailureFallsBackToPersistentPaneThenActivatesApp() async {
    let (routeExecutor, recorder) = executor(topologyData: topology(), failingCommand: "focus-panel")
    let navigator = CMUXNotificationNavigator(
        executor: routeExecutor,
        appActivator: CMUXAppActivator(activate: recorder.activate)
    )

    let result = await navigator.navigate(to: completeTarget)

    #expect(result.deepestSuccess == .pane)
    #expect(recorder.calls.suffix(2) == [
        ["focus-panel", "--panel", "surface:1", "--workspace", "WS", "--window", "W"],
        ["focus-pane", "--pane", "pane:1", "--workspace", "WS", "--window", "W"],
    ])
    #expect(recorder.activations == 1)
    #expect(recorder.events.suffix(3) == ["focus-panel", "focus-pane", "activate-app"])
}

@Test func refSurfaceFailureUsesRefPaneWithRefWorkspaceScope() {
    let current = topology(workspaceID: nil, paneID: nil, surfaceID: nil)
    let target = CMUXNavigationTarget(
        windowID: "W", workspaceRef: "workspace:1",
        paneRef: "pane:1", surfaceRef: "surface:1"
    )
    let (navigator, recorder) = executor(topologyData: current, failingCommand: "focus-panel")

    let result = navigator.navigate(to: target)

    #expect(result.deepestSuccess == .pane)
    #expect(recorder.calls.suffix(2) == [
        ["focus-panel", "--panel", "surface:1", "--workspace", "workspace:1", "--window", "W"],
        ["focus-pane", "--pane", "pane:1", "--workspace", "workspace:1", "--window", "W"],
    ])
}

@Test func refChildrenUsePersistentWorkspaceAndWindowScope() {
    let current = topology(paneID: nil, surfaceID: nil)
    let target = CMUXNavigationTarget(
        windowID: "W", workspaceID: "WS", paneRef: "pane:1", surfaceRef: "surface:1"
    )
    let (navigator, recorder) = executor(topologyData: current, failingCommand: "focus-panel")

    let result = navigator.navigate(to: target)

    #expect(result.deepestSuccess == .pane)
    #expect(recorder.calls.suffix(2) == [
        ["focus-panel", "--panel", "surface:1", "--workspace", "WS", "--window", "W"],
        ["focus-pane", "--pane", "pane:1", "--workspace", "WS", "--window", "W"],
    ])
}

@Test func movedPersistentSurfaceCannotOverrideItsCapturedPersistentParents() {
    let moved = topology(
        windowID: "W2", windowRef: "window:8",
        workspaceID: "WS2", workspaceRef: "workspace:8",
        paneID: "P2", paneRef: "pane:8",
        surfaceID: "S", surfaceRef: "surface:8"
    )
    let (navigator, recorder) = executor(topologyData: moved)

    let result = navigator.navigate(to: completeTarget)

    #expect(result.deepestSuccess == .none)
    #expect(recorder.calls == [["--json", "--id-format", "both", "tree", "--all"]])
}

@Test func unsupportedRefOnlyWindowFailsClosedToAppActivation() async {
    let current = topology(windowID: nil, workspaceID: nil, paneID: nil, surfaceID: nil)
    let target = CMUXNavigationTarget(
        windowRef: "window:1", workspaceRef: "workspace:1",
        paneRef: "pane:1", surfaceRef: "surface:1"
    )
    let (routeExecutor, recorder) = executor(topologyData: current)
    let navigator = CMUXNotificationNavigator(
        executor: routeExecutor,
        appActivator: CMUXAppActivator(activate: recorder.activate)
    )

    let result = await navigator.navigate(to: target)

    #expect(result.deepestSuccess == .app)
    #expect(recorder.calls.count == 1)
    #expect(recorder.activations == 1)
}

@Test func allFocusFailuresActivateCMUXAppOnceAfterRouteCommands() async {
    let (routeExecutor, recorder) = executor(topologyData: topology(), failingCommand: "*")
    let navigator = CMUXNotificationNavigator(
        executor: routeExecutor,
        appActivator: CMUXAppActivator(activate: recorder.activate)
    )

    let result = await navigator.navigate(to: completeTarget)

    #expect(result.deepestSuccess == .app)
    #expect(recorder.activations == 1)
    #expect(result.failures.allSatisfy { !$0.description.contains("W") && !$0.description.contains("S") })
}

private final class AppActivationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requestedBundleIdentifiers: [String] = []
    private(set) var activationOptionsCalls = 0
    private(set) var sleepNanoseconds: [UInt64] = []
    private var frontmostValues: [String?]

    init(frontmostValues: [String?]) {
        self.frontmostValues = frontmostValues
    }

    func locate(_ bundleIdentifier: String) -> (@MainActor @Sendable () -> Bool)? {
        lock.withLock { requestedBundleIdentifiers.append(bundleIdentifier) }
        return {
            self.lock.withLock { self.activationOptionsCalls += 1 }
            return true
        }
    }

    func frontmostBundleIdentifier() -> String? {
        lock.withLock {
            guard !frontmostValues.isEmpty else { return nil }
            return frontmostValues.removeFirst()
        }
    }

    func sleep(_ nanoseconds: UInt64) async throws {
        lock.withLock { sleepNanoseconds.append(nanoseconds) }
    }
}

@MainActor
@Test func appActivatorFindsOnlyCMUXActivatesAllWindowsAndWaitsForObservedForeground() async {
    let recorder = AppActivationRecorder(frontmostValues: ["other.app", "com.cmuxterm.app"])
    let activator = CMUXAppActivator(
        locateApplication: recorder.locate,
        frontmostBundleIdentifier: recorder.frontmostBundleIdentifier,
        sleep: recorder.sleep
    )

    let result = await activator.activate()

    #expect(result)
    #expect(recorder.requestedBundleIdentifiers == ["com.cmuxterm.app"])
    #expect(recorder.activationOptionsCalls == 1)
    #expect(recorder.sleepNanoseconds == [25_000_000, 25_000_000])
}

@MainActor
@Test func appActivatorFailsForMissingApplicationRejectedActivationAndTimeout() async {
    let missing = CMUXAppActivator(
        locateApplication: { _ in nil },
        frontmostBundleIdentifier: { "other.app" },
        sleep: { _ in }
    )
    #expect(await !missing.activate())

    let rejected = CMUXAppActivator(
        locateApplication: { _ in { false } },
        frontmostBundleIdentifier: { "com.cmuxterm.app" },
        sleep: { _ in }
    )
    #expect(await !rejected.activate())

    let timeoutRecorder = AppActivationRecorder(frontmostValues: [])
    let timedOut = CMUXAppActivator(
        locateApplication: { _ in { true } },
        frontmostBundleIdentifier: timeoutRecorder.frontmostBundleIdentifier,
        sleep: timeoutRecorder.sleep
    )
    #expect(await !timedOut.activate())
    #expect(timeoutRecorder.sleepNanoseconds.count == 40)
}

@MainActor
@Test func appActivatorFailsClosedWhenConfirmationIsCancelled() async {
    let activator = CMUXAppActivator(
        locateApplication: { _ in { true } },
        frontmostBundleIdentifier: { "other.app" },
        sleep: { _ in throw CancellationError() }
    )

    #expect(await !activator.activate())
}

@Test func activationFailurePreservesDeepestRouteAndAppendsSafeFailure() async {
    let (routeExecutor, recorder) = executor(topologyData: topology())
    let navigator = CMUXNotificationNavigator(
        executor: routeExecutor,
        appActivator: CMUXAppActivator(activate: { false })
    )

    let result = await navigator.navigate(to: completeTarget)

    #expect(result.deepestSuccess == .surface)
    #expect(result.failures == [.appActivationFailed])
    #expect(recorder.calls.last?.first == "focus-panel")
}

@Test func targetlessNavigationActivatesAppOnly() async {
    let recorder = NavigationRecorder()
    let routeExecutor = CMUXNavigationExecutor { arguments in
        recorder.append(arguments)
        return CMUXNavigationCommandResult(status: 0, output: Data())
    }
    let navigator = CMUXNotificationNavigator(
        executor: routeExecutor,
        appActivator: CMUXAppActivator(activate: recorder.activate)
    )

    let result = await navigator.navigate(to: Optional<CMUXNavigationTarget>.none)

    #expect(result == CMUXNavigationResult(deepestSuccess: .app, failures: []))
    #expect(recorder.calls.isEmpty)
    #expect(recorder.activations == 1)
}

@MainActor
@Test func asyncNavigatorDoesNotBlockMainActorDuringTopologyRead() async {
    let (executor, _) = executor(topologyData: topology(), topologyDelay: 0.15)
    let navigator = CMUXNotificationNavigator(executor: executor)
    let navigation = Task { await navigator.navigate(to: completeTarget) }

    await Task.yield()
    let markerReached = true
    let result = await navigation.value

    #expect(markerReached)
    #expect(result.deepestSuccess == .surface)
}

@Test func canceledNavigationDoesNotIssueLaterFocusOrActivationMutations() async {
    let recorder = NavigationRecorder()
    let windowStarted = DispatchSemaphore(value: 0)
    let windowMayReturn = DispatchSemaphore(value: 0)
    let command: @Sendable ([String]) throws -> CMUXNavigationCommandResult = { arguments in
        recorder.append(arguments)
        if arguments.first == "--json" {
            return CMUXNavigationCommandResult(status: 0, output: topology())
        }
        if arguments.first == "focus-window" {
            windowStarted.signal()
            windowMayReturn.wait()
        }
        return CMUXNavigationCommandResult(status: 0, output: Data())
    }
    let navigator = CMUXNotificationNavigator(
        executor: CMUXNavigationExecutor(command: command),
        appActivator: CMUXAppActivator(activate: recorder.activate)
    )
    let task = Task { await navigator.navigate(to: completeTarget) }
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            windowStarted.wait()
            continuation.resume()
        }
    }

    task.cancel()
    windowMayReturn.signal()
    let result = await task.value

    #expect(recorder.calls.contains { $0.first == "focus-window" })
    #expect(!recorder.calls.contains { $0.first == "select-workspace" })
    #expect(!recorder.calls.contains { $0.first == "focus-panel" })
    #expect(recorder.activations == 0)
    #expect(result.failures.contains(.cancelled))
}
