import AppKit
import Foundation
import NextUpCore

struct CMUXAppActivator: Sendable {
    typealias ActivateAllWindows = @MainActor @Sendable () -> Bool

    private let activation: @MainActor @Sendable () async -> Bool

    init(activate: @escaping @MainActor @Sendable () -> Bool) {
        activation = { activate() }
    }

    init(
        locateApplication: @escaping @MainActor @Sendable (String) -> ActivateAllWindows?,
        frontmostBundleIdentifier: @escaping @MainActor @Sendable () -> String?,
        sleep: @escaping @Sendable (UInt64) async throws -> Void
    ) {
        activation = {
            let bundleIdentifier = "com.cmuxterm.app"
            guard let activateAllWindows = locateApplication(bundleIdentifier) else { return false }
            guard activateAllWindows() else { return false }
            do {
                for _ in 0..<40 {
                    try await sleep(25_000_000)
                    if frontmostBundleIdentifier() == bundleIdentifier { return true }
                }
            } catch {
                return false
            }
            return false
        }
    }

    init() {
        self.init(
            locateApplication: { bundleIdentifier in
                guard let application = NSRunningApplication.runningApplications(
                    withBundleIdentifier: bundleIdentifier
                ).first else { return nil }
                return {
                    application.activate(options: [.activateAllWindows])
                }
            },
            frontmostBundleIdentifier: {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            },
            sleep: { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        )
    }

    @MainActor
    func activate() async -> Bool {
        await activation()
    }
}

struct CMUXNavigationCommandResult: Sendable {
    let status: Int32
    let output: Data
}

enum CMUXNavigationLevel: String, Codable, Sendable, CaseIterable {
    case none
    case app
    case window
    case workspace
    case pane
    case surface

    fileprivate var rank: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

enum CMUXNavigationFailure: Codable, Equatable, Sendable, CustomStringConvertible {
    case topologyUnavailable
    case commandFailed(CMUXNavigationLevel)
    case appActivationFailed
    case cancelled

    var description: String {
        switch self {
        case .topologyUnavailable: "topology-unavailable"
        case let .commandFailed(level): "command-failed-\(level.rawValue)"
        case .appActivationFailed: "app-activation-failed"
        case .cancelled: "navigation-cancelled"
        }
    }
}

struct CMUXNavigationResult: Codable, Equatable, Sendable {
    let deepestSuccess: CMUXNavigationLevel
    let failures: [CMUXNavigationFailure]
}

struct CMUXNavigationExecutor: Sendable {
    private let command: @Sendable ([String]) throws -> CMUXNavigationCommandResult

    init(
        executable: String = "/Applications/cmux.app/Contents/Resources/bin/cmux",
        commandDeadline: TimeInterval = 3
    ) {
        let executableURL = URL(fileURLWithPath: executable)
        let environment = CMUXClient.childEnvironment()
        command = { arguments in
            let result = try BoundedProcessRunner().run(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                deadline: commandDeadline
            )
            return CMUXNavigationCommandResult(
                status: result.terminationStatus,
                output: result.standardOutput
            )
        }
    }

    init(
        command: @escaping @Sendable ([String]) throws -> CMUXNavigationCommandResult
    ) {
        self.command = command
    }

    func navigate(to target: CMUXNavigationTarget) -> CMUXNavigationResult {
        guard !Task.isCancelled else {
            return CMUXNavigationResult(deepestSuccess: .none, failures: [.cancelled])
        }
        let topology: NavigationTopology
        do {
            let result = try command(["--json", "--id-format", "both", "tree", "--all"])
            guard result.status == 0 else {
                if Task.isCancelled {
                    return CMUXNavigationResult(deepestSuccess: .none, failures: [.cancelled])
                }
                return CMUXNavigationResult(deepestSuccess: .none, failures: [.topologyUnavailable])
            }
            topology = try NavigationTopology(data: result.output)
        } catch {
            if Task.isCancelled {
                return CMUXNavigationResult(deepestSuccess: .none, failures: [.cancelled])
            }
            return CMUXNavigationResult(deepestSuccess: .none, failures: [.topologyUnavailable])
        }
        guard !Task.isCancelled else {
            return CMUXNavigationResult(deepestSuccess: .none, failures: [.cancelled])
        }

        let route = topology.resolve(target)
        var deepest: CMUXNavigationLevel = .none
        var failures: [CMUXNavigationFailure] = []

        func attempt(_ level: CMUXNavigationLevel, _ arguments: [String]?) -> Bool {
            guard !Task.isCancelled else { return false }
            guard let arguments else { return false }
            do {
                let result = try command(arguments)
                guard result.status == 0 else {
                    failures.append(.commandFailed(level))
                    return false
                }
                if level.rank > deepest.rank { deepest = level }
                return true
            } catch {
                failures.append(.commandFailed(level))
                return false
            }
        }

        _ = attempt(.window, route.windowArguments)
        _ = attempt(.workspace, route.workspaceArguments)
        let surfaceSucceeded = attempt(.surface, route.surfaceArguments)
        if !surfaceSucceeded {
            _ = attempt(.pane, route.paneArguments)
        }

        if Task.isCancelled {
            return CMUXNavigationResult(
                deepestSuccess: deepest,
                failures: failures + [.cancelled]
            )
        }

        return CMUXNavigationResult(deepestSuccess: deepest, failures: failures)
    }
}

struct CMUXNotificationNavigator: Sendable {
    let executor: CMUXNavigationExecutor
    let appActivator: CMUXAppActivator

    init(
        executor: CMUXNavigationExecutor = CMUXNavigationExecutor(),
        appActivator: CMUXAppActivator = CMUXAppActivator()
    ) {
        self.executor = executor
        self.appActivator = appActivator
    }

    func navigate(to target: CMUXNavigationTarget) async -> CMUXNavigationResult {
        let operation = Task.detached(priority: .userInitiated) {
            executor.navigate(to: target)
        }
        let result = await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
        guard !Task.isCancelled else { return result }
        guard await appActivator.activate() else {
            return CMUXNavigationResult(
                deepestSuccess: result.deepestSuccess,
                failures: result.failures + [.appActivationFailed]
            )
        }
        return CMUXNavigationResult(
            deepestSuccess: result.deepestSuccess == .none ? .app : result.deepestSuccess,
            failures: result.failures
        )
    }

    func navigate(to target: CMUXNavigationTarget?) async -> CMUXNavigationResult {
        if let target {
            return await navigate(to: target)
        }
        guard !Task.isCancelled else {
            return CMUXNavigationResult(deepestSuccess: .none, failures: [.cancelled])
        }
        guard await appActivator.activate() else {
            return CMUXNavigationResult(deepestSuccess: .none, failures: [.appActivationFailed])
        }
        return CMUXNavigationResult(deepestSuccess: .app, failures: [])
    }
}

private struct NavigationTopology: Sendable {
    struct Window: Sendable {
        let id: String?
        let ref: String?
        let workspaces: [Workspace]
    }

    struct Workspace: Sendable {
        let id: String?
        let ref: String?
        let panes: [Pane]
    }

    struct Pane: Sendable {
        let id: String?
        let ref: String?
        let surfaces: [Surface]
    }

    struct Surface: Sendable {
        let id: String?
        let ref: String?
    }

    struct WorkspacePath: Sendable {
        let window: Window
        let workspace: Workspace
    }

    struct PanePath: Sendable {
        let window: Window
        let workspace: Workspace
        let pane: Pane
    }

    struct SurfacePath: Sendable {
        let window: Window
        let workspace: Workspace
        let pane: Pane
        let surface: Surface
    }

    let windows: [Window]

    init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawWindows = root["windows"] as? [[String: Any]] else {
            throw TopologyError.invalidRoot
        }
        windows = rawWindows.map { rawWindow in
            let rawWorkspaces = rawWindow["workspaces"] as? [[String: Any]] ?? []
            return Window(
                id: rawWindow["id"] as? String,
                ref: rawWindow["ref"] as? String,
                workspaces: rawWorkspaces.map { rawWorkspace in
                    let rawPanes = rawWorkspace["panes"] as? [[String: Any]] ?? []
                    return Workspace(
                        id: rawWorkspace["id"] as? String,
                        ref: rawWorkspace["ref"] as? String,
                        panes: rawPanes.map { rawPane in
                            let rawSurfaces = rawPane["surfaces"] as? [[String: Any]] ?? []
                            return Pane(
                                id: rawPane["id"] as? String,
                                ref: rawPane["ref"] as? String,
                                surfaces: rawSurfaces.map {
                                    Surface(id: $0["id"] as? String, ref: $0["ref"] as? String)
                                }
                            )
                        }
                    )
                }
            )
        }
    }

    func resolve(_ target: CMUXNavigationTarget) -> ResolvedRoute {
        let exactWindow = target.windowID.flatMap(uniqueWindow(id:))

        var workspacePath: WorkspacePath?
        if let workspaceID = target.workspaceID {
            workspacePath = target.windowID != nil
                ? exactWindow.flatMap { uniqueWorkspace(id: workspaceID, in: $0) }
                : uniqueWorkspace(id: workspaceID)
        }
        if workspacePath == nil,
           target.workspaceID == nil,
           let window = exactWindow,
           let workspaceRef = target.workspaceRef {
            workspacePath = uniqueWorkspace(ref: workspaceRef, in: window)
        }

        var panePath: PanePath?
        if let paneID = target.paneID {
            if target.workspaceID != nil || target.workspaceRef != nil {
                panePath = workspacePath.flatMap { uniquePane(id: paneID, in: $0) }
            } else if let exactWindow, target.windowID != nil {
                panePath = uniquePane(id: paneID, in: exactWindow)
            } else {
                panePath = uniquePane(id: paneID)
            }
        }
        if panePath == nil,
           target.paneID == nil,
           let workspacePath,
           let paneRef = target.paneRef {
            panePath = uniquePane(ref: paneRef, in: workspacePath)
        }

        var surfacePath: SurfacePath?
        if let surfaceID = target.surfaceID {
            if target.paneID != nil || target.paneRef != nil {
                surfacePath = panePath.flatMap { uniqueSurface(id: surfaceID, in: $0) }
            } else if target.workspaceID != nil || target.workspaceRef != nil {
                surfacePath = workspacePath.flatMap { uniqueSurface(id: surfaceID, in: $0) }
            } else if let exactWindow, target.windowID != nil {
                surfacePath = uniqueSurface(id: surfaceID, in: exactWindow)
            } else {
                surfacePath = uniqueSurface(id: surfaceID)
            }
        }
        if surfacePath == nil,
           target.surfaceID == nil,
           let surfaceRef = target.surfaceRef {
            if target.paneID != nil || target.paneRef != nil {
                if let panePath {
                    surfacePath = uniqueSurface(ref: surfaceRef, in: panePath)
                }
            } else if let workspacePath {
                surfacePath = uniqueSurface(ref: surfaceRef, in: workspacePath)
            }
        }

        if let surfacePath {
            panePath = PanePath(
                window: surfacePath.window,
                workspace: surfacePath.workspace,
                pane: surfacePath.pane
            )
            workspacePath = WorkspacePath(
                window: surfacePath.window,
                workspace: surfacePath.workspace
            )
        } else if let panePath {
            workspacePath = WorkspacePath(window: panePath.window, workspace: panePath.workspace)
        }

        let window = surfacePath?.window ?? panePath?.window ?? workspacePath?.window ?? exactWindow
        return ResolvedRoute(
            window: window,
            workspacePath: workspacePath,
            panePath: panePath,
            surfacePath: surfacePath
        )
    }

    private func uniqueWindow(id: String) -> Window? {
        windows.only { $0.id == id }
    }

    private func uniqueWorkspace(id: String) -> WorkspacePath? {
        windows.flatMap { window in
            window.workspaces.compactMap { workspace in
                workspace.id == id ? WorkspacePath(window: window, workspace: workspace) : nil
            }
        }.only
    }

    private func uniqueWorkspace(id: String, in window: Window) -> WorkspacePath? {
        window.workspaces.compactMap { workspace in
            workspace.id == id ? WorkspacePath(window: window, workspace: workspace) : nil
        }.only
    }

    private func uniquePane(id: String) -> PanePath? {
        windows.flatMap { window in
            window.workspaces.flatMap { workspace in
                workspace.panes.compactMap { pane in
                    pane.id == id ? PanePath(window: window, workspace: workspace, pane: pane) : nil
                }
            }
        }.only
    }

    private func uniquePane(id: String, in window: Window) -> PanePath? {
        window.workspaces.flatMap { workspace in
            workspace.panes.compactMap { pane in
                pane.id == id ? PanePath(window: window, workspace: workspace, pane: pane) : nil
            }
        }.only
    }

    private func uniquePane(id: String, in workspacePath: WorkspacePath) -> PanePath? {
        workspacePath.workspace.panes.compactMap { pane in
            pane.id == id
                ? PanePath(window: workspacePath.window, workspace: workspacePath.workspace, pane: pane)
                : nil
        }.only
    }

    private func uniqueSurface(id: String) -> SurfacePath? {
        windows.flatMap { window in
            window.workspaces.flatMap { workspace in
                workspace.panes.flatMap { pane in
                    pane.surfaces.compactMap { surface in
                        surface.id == id
                            ? SurfacePath(window: window, workspace: workspace, pane: pane, surface: surface)
                            : nil
                    }
                }
            }
        }.only
    }

    private func uniqueSurface(id: String, in window: Window) -> SurfacePath? {
        window.workspaces.flatMap { workspace in
            workspace.panes.flatMap { pane in
                pane.surfaces.compactMap { surface in
                    surface.id == id
                        ? SurfacePath(window: window, workspace: workspace, pane: pane, surface: surface)
                        : nil
                }
            }
        }.only
    }

    private func uniqueSurface(id: String, in workspacePath: WorkspacePath) -> SurfacePath? {
        workspacePath.workspace.panes.flatMap { pane in
            pane.surfaces.compactMap { surface in
                surface.id == id
                    ? SurfacePath(
                        window: workspacePath.window,
                        workspace: workspacePath.workspace,
                        pane: pane,
                        surface: surface
                    )
                    : nil
            }
        }.only
    }

    private func uniqueSurface(id: String, in panePath: PanePath) -> SurfacePath? {
        panePath.pane.surfaces.compactMap { surface in
            surface.id == id
                ? SurfacePath(
                    window: panePath.window,
                    workspace: panePath.workspace,
                    pane: panePath.pane,
                    surface: surface
                )
                : nil
        }.only
    }

    private func uniqueWorkspace(ref: String, in window: Window) -> WorkspacePath? {
        window.workspaces.compactMap { workspace in
            workspace.ref == ref ? WorkspacePath(window: window, workspace: workspace) : nil
        }.only
    }

    private func uniquePane(ref: String, in workspacePath: WorkspacePath) -> PanePath? {
        workspacePath.workspace.panes.compactMap { pane in
            pane.ref == ref
                ? PanePath(window: workspacePath.window, workspace: workspacePath.workspace, pane: pane)
                : nil
        }.only
    }

    private func uniqueSurface(ref: String, in workspacePath: WorkspacePath) -> SurfacePath? {
        workspacePath.workspace.panes.flatMap { pane in
            pane.surfaces.compactMap { surface in
                surface.ref == ref
                    ? SurfacePath(
                        window: workspacePath.window,
                        workspace: workspacePath.workspace,
                        pane: pane,
                        surface: surface
                    )
                    : nil
            }
        }.only
    }

    private func uniqueSurface(ref: String, in panePath: PanePath) -> SurfacePath? {
        panePath.pane.surfaces.compactMap { surface in
            surface.ref == ref
                ? SurfacePath(
                    window: panePath.window,
                    workspace: panePath.workspace,
                    pane: panePath.pane,
                    surface: surface
                )
                : nil
        }.only
    }

    enum TopologyError: Error {
        case invalidRoot
    }
}

private struct ResolvedRoute: Sendable {
    let window: NavigationTopology.Window?
    let workspacePath: NavigationTopology.WorkspacePath?
    let panePath: NavigationTopology.PanePath?
    let surfacePath: NavigationTopology.SurfacePath?

    var windowArguments: [String]? {
        window?.id.map { ["focus-window", "--window", $0] }
    }

    var workspaceArguments: [String]? {
        guard let workspacePath else { return nil }
        if let id = workspacePath.workspace.id {
            return ["select-workspace", "--workspace", id]
        }
        guard let ref = workspacePath.workspace.ref, let windowID = workspacePath.window.id else {
            return nil
        }
        return ["select-workspace", "--workspace", ref, "--window", windowID]
    }

    var surfaceArguments: [String]? {
        guard let surfacePath else { return nil }
        guard let surfaceRef = surfacePath.surface.ref,
              let workspace = scopedWorkspace(in: surfacePath.window, surfacePath.workspace) else {
            return nil
        }
        return ["focus-panel", "--panel", surfaceRef] + workspace
    }

    var paneArguments: [String]? {
        guard let panePath else { return nil }
        guard let paneRef = panePath.pane.ref,
              let workspace = scopedWorkspace(in: panePath.window, panePath.workspace) else {
            return nil
        }
        return ["focus-pane", "--pane", paneRef] + workspace
    }

    private func scopedWorkspace(
        in window: NavigationTopology.Window,
        _ workspace: NavigationTopology.Workspace
    ) -> [String]? {
        guard let windowID = window.id else { return nil }
        if let workspaceID = workspace.id {
            return ["--workspace", workspaceID, "--window", windowID]
        }
        if let workspaceRef = workspace.ref {
            return ["--workspace", workspaceRef, "--window", windowID]
        }
        return nil
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }

    func only(where predicate: (Element) throws -> Bool) rethrows -> Element? {
        let matches = try filter(predicate)
        return matches.only
    }
}
