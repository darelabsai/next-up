import Foundation
import NextUpCore

struct HermesSessionEnrichment: Sendable {
    let lanes: [LaneSnapshot]
    let bindingCount: Int
    let newlyResolved: Int
    let sessionSummaryCount: Int
}

actor HermesSessionService {
    private let client: any HermesSessionBridgeClient
    private let cacheURL: URL
    private var cache: HermesSessionBindingCache
    private var attemptedEvidence: [String: String] = [:]

    init(
        cacheURL: URL,
        client: any HermesSessionBridgeClient = JarvisBridgeClient()
    ) {
        self.cacheURL = cacheURL
        self.client = client
        if let data = try? Data(contentsOf: cacheURL),
           let restored = try? JSONDecoder().decode(HermesSessionBindingCache.self, from: data) {
            cache = restored
        } else {
            cache = HermesSessionBindingCache()
        }
    }

    func enrich(
        lanes: [LaneSnapshot],
        completionCandidateIDs: Set<String>,
        retainingSurfacePersistentIDs: Set<String>? = nil,
        now: Date = Date()
    ) async -> HermesSessionEnrichment {
        let eligibleLanes = HermesSessionEnrichmentPolicy.eligibleLanes(from: lanes)
        let livePersistentIDs = retainingSurfacePersistentIDs
            ?? Set(lanes.compactMap(\.persistentID))
        let oldCount = cache.bindings.count
        cache.retain(surfacePersistentIDs: livePersistentIDs)
        attemptedEvidence = attemptedEvidence.filter { livePersistentIDs.contains($0.key) }

        let ordered = eligibleLanes.sorted {
            let leftPriority = completionCandidateIDs.contains($0.id) ? 0 : 1
            let rightPriority = completionCandidateIDs.contains($1.id) ? 0 : 1
            return leftPriority == rightPriority ? $0.id < $1.id : leftPriority < rightPriority
        }
        var discoveryLanes: [LaneSnapshot] = []
        for lane in ordered {
            guard cache.binding(for: lane) == nil,
                  let surfaceID = lane.persistentID,
                  lane.workspacePersistentID != nil,
                  lane.machine == "mac-air" || lane.machine == "mac-mini" else { continue }
            let evidence = [
                lane.machine, lane.hermesProfile, lane.title, lane.matchingSnippet ?? "",
            ].joined(separator: "\u{1f}")
            guard attemptedEvidence[surfaceID] != evidence else { continue }
            attemptedEvidence[surfaceID] = evidence
            discoveryLanes.append(lane)
            if discoveryLanes.count == 6 { break }
        }

        let bridge = client
        let discoveryResults = await withTaskGroup(of: DiscoveryResult?.self) { group in
            for lane in discoveryLanes {
                group.addTask {
                    guard let resolved = try? bridge.discover(lane: lane, now: now) else { return nil }
                    return DiscoveryResult(
                        laneID: lane.id,
                        binding: resolved.0,
                        turn: resolved.1
                    )
                }
            }
            var results: [DiscoveryResult] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        var discoveredTurns: [String: HermesFinalTurn] = [:]
        for result in discoveryResults {
            cache.remember(result.binding)
            if let turn = result.turn { discoveredTurns[result.laneID] = turn }
        }

        let completionLanes = eligibleLanes.filter { completionCandidateIDs.contains($0.id) }
        let retrievalResults = await withTaskGroup(of: TurnResult.self) { group in
            for lane in completionLanes {
                if let turn = discoveredTurns[lane.id] {
                    group.addTask { TurnResult(laneID: lane.id, turn: turn, failedSurfaceID: nil) }
                } else if let binding = cache.binding(for: lane) {
                    group.addTask {
                        do {
                            return TurnResult(
                                laneID: lane.id,
                                turn: try bridge.latestTurn(binding: binding),
                                failedSurfaceID: nil
                            )
                        } catch {
                            return TurnResult(
                                laneID: lane.id, turn: nil,
                                failedSurfaceID: binding.surfacePersistentID
                            )
                        }
                    }
                }
            }
            var results: [TurnResult] = []
            for await result in group { results.append(result) }
            return results
        }

        var summaries: [String: String] = [:]
        for result in retrievalResults {
            if let surfaceID = result.failedSurfaceID {
                cache.invalidate(surfacePersistentID: surfaceID)
                attemptedEvidence.removeValue(forKey: surfaceID)
            }
            if let turn = result.turn,
               let summary = BoundedTurnSummary.summarize(turn) {
                summaries[result.laneID] = summary
            }
        }

        if oldCount != cache.bindings.count || !discoveryResults.isEmpty || !retrievalResults.isEmpty {
            persist()
        }
        let enriched = lanes.map { lane in
            guard let summary = summaries[lane.id] else { return lane }
            return lane.withSummary(summary)
        }
        return HermesSessionEnrichment(
            lanes: enriched,
            bindingCount: cache.bindings.count,
            newlyResolved: discoveryResults.count,
            sessionSummaryCount: summaries.count
        )
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }
}

private struct DiscoveryResult: Sendable {
    let laneID: String
    let binding: HermesSessionBinding
    let turn: HermesFinalTurn?
}

private struct TurnResult: Sendable {
    let laneID: String
    let turn: HermesFinalTurn?
    let failedSurfaceID: String?
}
