import Foundation
import Testing
@testable import NextUp
@testable import NextUpCore

private final class ZeroCallHermesBridge: HermesSessionBridgeClient, @unchecked Sendable {
    private let lock = NSLock()
    private var discoveryStorage = 0
    private var retrievalStorage = 0

    var discoveryCalls: Int { lock.withLock { discoveryStorage } }
    var retrievalCalls: Int { lock.withLock { retrievalStorage } }

    func discover(
        lane: LaneSnapshot,
        now: Date
    ) throws -> (HermesSessionBinding, HermesFinalTurn?)? {
        lock.withLock { discoveryStorage += 1 }
        return nil
    }

    func latestTurn(binding: HermesSessionBinding) throws -> HermesFinalTurn? {
        lock.withLock { retrievalStorage += 1 }
        return nil
    }
}

@Test func actualHermesSessionServiceMakesZeroBridgeCallsForInputRequiredLane() async {
    let bridge = ZeroCallHermesBridge()
    let cacheURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("next-up-zero-call-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: cacheURL) }
    let service = HermesSessionService(cacheURL: cacheURL, client: bridge)
    let inputLane = LaneSnapshot(
        id: "surface:private",
        persistentID: "PRIVATE-SURFACE",
        title: "Private lane",
        state: .inputRequired,
        inputRequestKind: .approval,
        summary: "PRIVATE-SUMMARY",
        matchingSnippet: "PRIVATE-SNIPPET",
        workspaceID: "workspace:private",
        workspacePersistentID: "PRIVATE-WORKSPACE",
        workspaceTitle: "Private workspace",
        machine: "mac-mini"
    )

    let result = await service.enrich(
        lanes: [inputLane],
        completionCandidateIDs: [inputLane.id]
    )

    #expect(result.lanes == [inputLane])
    #expect(bridge.discoveryCalls == 0)
    #expect(bridge.retrievalCalls == 0)
}

@Test func quarantinedLiveLaneRetainsExistingHermesBindingWithoutBridgeCalls() async throws {
    let bridge = ZeroCallHermesBridge()
    let cacheURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("next-up-quarantine-cache-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: cacheURL) }
    let binding = HermesSessionBinding(
        surfacePersistentID: "LIVE-SURFACE",
        workspacePersistentID: "LIVE-WORKSPACE",
        machine: "mac-mini",
        profile: "default",
        sessionID: "session-private",
        matchMethod: "exact",
        resolvedAt: Date(timeIntervalSince1970: 1)
    )
    try JSONEncoder().encode(HermesSessionBindingCache(
        bindings: [binding.surfacePersistentID: binding]
    )).write(to: cacheURL)
    let service = HermesSessionService(cacheURL: cacheURL, client: bridge)

    _ = await service.enrich(
        lanes: [],
        completionCandidateIDs: [],
        retainingSurfacePersistentIDs: [binding.surfacePersistentID]
    )

    let persisted = try JSONDecoder().decode(
        HermesSessionBindingCache.self,
        from: Data(contentsOf: cacheURL)
    )
    #expect(persisted.bindings == [binding.surfacePersistentID: binding])
    #expect(bridge.discoveryCalls == 0)
    #expect(bridge.retrievalCalls == 0)
}
