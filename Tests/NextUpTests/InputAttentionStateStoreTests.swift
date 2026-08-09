import Foundation
import Testing
import NextUpCore
@testable import NextUp

@Test func inputAttentionStateStoreTreatsAbsentFileAsEmptyMigration() throws {
    let url = temporaryInputAttentionURL()
    let store = InputAttentionStateStore(url: url)

    #expect(store.load() == InputAttentionTracker())
}

@Test func inputAttentionStateStoreRoundTripsAcknowledgedRoute() throws {
    let url = temporaryInputAttentionURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = InputAttentionStateStore(url: url)
    var tracker = InputAttentionTracker()
    tracker.observe([LaneSnapshot(
        id: "lane",
        title: "Approval",
        state: .inputRequired,
        navigationTarget: CMUXNavigationTarget(
            windowID: "window", windowRef: "window-ref",
            workspaceID: "workspace", workspaceRef: "workspace-ref",
            paneID: "pane", paneRef: "pane-ref",
            surfaceID: "surface", surfaceRef: "surface-ref"
        )
    )])
    tracker.acknowledge(laneID: "lane")

    try store.save(tracker)

    #expect(store.load() == tracker)
    #expect(store.load().isAcknowledged(laneID: "lane"))
}

@Test func inputAttentionStateStoreFailsClosedOnMalformedState() throws {
    let url = temporaryInputAttentionURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("not-json".utf8).write(to: url)

    #expect(InputAttentionStateStore(url: url).load() == InputAttentionTracker())
}

private func temporaryInputAttentionURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("nextup-input-state-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("input-attention-state.json")
}
