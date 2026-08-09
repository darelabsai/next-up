import Foundation
import Testing
@testable import NextUp
@testable import NextUpCore

@Test func pendingProbeReturnsPrivacySafeCadenceForExactLaneRef() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("next-up-pending-probe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    var state = LaneMonitorState()
    state.observe([
        LaneSnapshot(id: "surface:42", title: "PRIVATE TITLE", state: .busy)
    ], now: Date(timeIntervalSince1970: 100))
    state.observe([
        LaneSnapshot(
            id: "surface:42", title: "PRIVATE TITLE", state: .ready,
            summary: "PRIVATE SUMMARY"
        )
    ], now: Date(timeIntervalSince1970: 101))
    state.markAnnounced(laneIDs: ["surface:42"], at: Date(timeIntervalSince1970: 105))
    state.markAnnounced(laneIDs: ["surface:42"], at: Date(timeIntervalSince1970: 110.125))
    try JSONEncoder().encode(state).write(to: stateURL)

    let payload = try PendingStateProbe.read(laneID: "surface:42", stateURL: stateURL)
    let rendered = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)

    #expect(payload == PendingStateProbe.Payload(
        pending: true, announcementCount: 2, lastAnnouncedAtUnixMilliseconds: 110_125
    ))
    #expect(!rendered.contains("PRIVATE"))
    #expect(!rendered.contains("surface:42"))
}

@Test func pendingProbeReturnsOnlyFalseForAbsentLaneOrStateFile() throws {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("next-up-missing-\(UUID().uuidString)/state.json")

    #expect(try PendingStateProbe.read(laneID: "surface:42", stateURL: missing) == .init(
        pending: false, announcementCount: nil, lastAnnouncedAtUnixMilliseconds: nil
    ))
}

@Test func pendingProbeRejectsEmptyLaneAndCorruptState() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("next-up-corrupt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    try Data("not-json".utf8).write(to: stateURL)

    #expect(throws: PendingStateProbe.ProbeError.self) {
        _ = try PendingStateProbe.read(laneID: "", stateURL: stateURL)
    }
    #expect(throws: DecodingError.self) {
        _ = try PendingStateProbe.read(laneID: "surface:42", stateURL: stateURL)
    }
}
