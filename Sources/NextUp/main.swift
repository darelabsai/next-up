import AppKit
import SwiftUI
import NextUpCore
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = WatcherModel()
    nonisolated private let notificationNavigator = CMUXNotificationNavigator()
    private var escapeMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 440, height: 640)
        popover.contentViewController = NSHostingController(rootView: NextUpView(model: model))
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.popover.isShown == true else { return event }
            self?.popover.performClose(nil)
            return nil
        }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "Next Up — SC lane completions"
        }
        model.onUpdate = { [weak self] in self?.refreshStatusItem() }
        refreshStatusItem()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let inputRequired = model.lanes.filter { $0.state == .inputRequired }.count
        let working = model.lanes.filter { $0.state == .busy }.count
        let waiting = model.lanes.filter { $0.state == .ready }.count
        let alerts = model.pending.count + inputRequired
        let symbol = alerts > 0 ? "bell.badge.fill" : (working > 0 ? "bell.fill" : "bell")
        let palette = NSImage.SymbolConfiguration(paletteColors: [.white])
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Next Up")?
            .withSymbolConfiguration(palette)
        image?.isTemplate = false
        button.image = image

        let title = inputRequired > 0 ? " \(inputRequired)" : (working > 0 ? " \(working)" : (alerts > 0 ? " \(alerts)" : ""))
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: NSColor.white]
        )
        button.toolTip = "Next Up — \(inputRequired) need input, \(working) working, \(waiting) waiting"
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo.reduce(into: [String: String]()) {
            if let key = $1.key as? String, let value = $1.value as? String {
                $0[key] = value
            }
        }
        switch NotificationResponseRouter.route(
            actionIdentifier: response.actionIdentifier,
            userInfo: userInfo
        ) {
        case let .navigate(target, acknowledgingLaneID):
            if let acknowledgingLaneID {
                await MainActor.run { [weak self] in
                    self?.model.acknowledge(acknowledgingLaneID)
                }
            }
            _ = await notificationNavigator.navigate(to: target)
        case let .acknowledge(laneID):
            await MainActor.run { [weak self] in
                self?.model.acknowledge(laneID)
            }
        case .ignore:
            break
        }
    }
}

private struct ProbeLane: Encodable {
    let id: String
    let persistentID: String?
    let title: String
    let state: LaneState
    let inputRequestKind: InputRequestKind?
    let summary: String?
    let workspaceID: String
    let workspacePersistentID: String?
    let workspaceTitle: String
    let machine: String
    let hermesProfile: String

    init(_ lane: LaneSnapshot) {
        id = lane.id
        persistentID = lane.persistentID
        title = lane.title
        state = lane.state
        inputRequestKind = lane.inputRequestKind
        summary = lane.summary
        workspaceID = lane.workspaceID
        workspacePersistentID = lane.workspacePersistentID
        workspaceTitle = lane.workspaceTitle
        machine = lane.machine
        hermesProfile = lane.hermesProfile
    }
}

private func announcementProbePayload() -> [String: InputAttentionAnnouncementPlan] {
    let build = LaneSnapshot(
        id: "build", title: "⚠️ Build lane · gpt",
        state: .inputRequired, inputRequestKind: .approval
    )
    let research = LaneSnapshot(
        id: "research", title: "Research lane",
        state: .inputRequired, inputRequestKind: .clarification
    )
    let deploy = LaneSnapshot(
        id: "deploy", title: "Deploy lane",
        state: .inputRequired, inputRequestKind: .response
    )
    func plan(_ lanes: [LaneSnapshot]) -> InputAttentionAnnouncementPlan {
        InputAttentionAnnouncementPlanner.plan(
            lanes: lanes,
            dueLaneIDs: Set(lanes.map(\.id)),
            voiceMode: .titleAndSummary,
            completionsAreDue: true
        )
    }
    return [
        "approval": plan([build]),
        "clarification": plan([research]),
        "response": plan([deploy]),
        "mixed": plan([build, research, deploy]),
    ]
}

private enum CommandProbeError: Error {
    case invalidUTF8
}

if CommandLine.arguments.contains("--navigation-probe") {
    let target: CMUXNavigationTarget
    do {
        target = try JSONDecoder().decode(
            CMUXNavigationTarget.self,
            from: BoundedProbeInput.read(maximumBytes: 4_096)
        )
    } catch {
        fputs("navigation probe failed\n", stderr)
        exit(EXIT_FAILURE)
    }
    Task { @MainActor in
        do {
            let result = await CMUXNotificationNavigator().navigate(to: target)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
            exit(EXIT_SUCCESS)
        } catch {
            fputs("navigation probe failed\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--alert-list-probe") {
    do {
        let input = try BoundedProbeInput.read(maximumBytes: 4_096)
        guard let laneID = String(data: input, encoding: .utf8)?
            .trimmingCharacters(in: .newlines) else {
            throw CommandProbeError.invalidUTF8
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("NextUp", isDirectory: true)
        let payload = try FocusedAttentionProbe.alertList(
            laneID: laneID,
            transactionStateURL: base.appendingPathComponent("watcher-transaction.json")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(payload), as: UTF8.self))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("alert list probe failed\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--focused-lane-probe") {
    do {
        let request = try JSONDecoder().decode(
            FocusedLaneProbeRequest.self,
            from: BoundedProbeInput.read(maximumBytes: 8_192)
        )
        let observation = CMUXClient().acquireFreshFocus()
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("NextUp", isDirectory: true)
        let transactionState = FocusedAttentionProbe.persistedTransactionState(
            at: base.appendingPathComponent("watcher-transaction.json")
        )
        let payload = FocusedAttentionProbe.evaluate(
            request: request,
            observation: observation,
            transactionState: transactionState,
            reconciledAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(payload), as: UTF8.self))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("focused lane probe failed\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--pending-probe") {
    do {
        let input = try BoundedProbeInput.read(maximumBytes: 4_096)
        guard let laneID = String(data: input, encoding: .utf8)?
            .trimmingCharacters(in: .newlines) else {
            throw CommandProbeError.invalidUTF8
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let payload = try PendingStateProbe.read(
            laneID: laneID,
            transactionStateURL: support.appendingPathComponent("NextUp/watcher-transaction.json")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(payload), as: UTF8.self))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("pending probe failed\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--announcement-probe") {
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(announcementProbePayload())
        print(String(decoding: data, as: UTF8.self))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--probe") {
    do {
        let result = try CMUXClient().fetch(selection: WorkspaceSelection())
        let data = try JSONEncoder().encode(result.lanes.map(ProbeLane.init))
        print(String(decoding: data, as: UTF8.self))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
