import Foundation
import Testing
@testable import NextUpCore

@Test func bindingCacheUsesPersistentSurfaceIdentityAndProvenance() throws {
    let lane = LaneSnapshot(
        id: "surface:55", persistentID: "SURFACE-UUID", title: "Lane", state: .ready,
        workspaceID: "workspace:6", workspacePersistentID: "WORKSPACE-UUID",
        machine: "mac-mini", hermesProfile: "default"
    )
    let binding = HermesSessionBinding(
        surfacePersistentID: "SURFACE-UUID", workspacePersistentID: "WORKSPACE-UUID",
        machine: "mac-mini", profile: "default", sessionID: "20260805_abc123",
        matchMethod: "snippet", resolvedAt: Date(timeIntervalSince1970: 100)
    )
    var cache = HermesSessionBindingCache()
    cache.remember(binding)

    #expect(cache.binding(for: lane) == binding)
    #expect(cache.binding(for: LaneSnapshot(
        id: lane.id, persistentID: lane.persistentID, title: lane.title, state: lane.state,
        workspaceID: lane.workspaceID, workspacePersistentID: lane.workspacePersistentID,
        machine: "mac-air"
    )) == nil)

    let restored = try JSONDecoder().decode(
        HermesSessionBindingCache.self,
        from: JSONEncoder().encode(cache)
    )
    #expect(restored.binding(for: lane) == binding)
}

@Test func bindingCachePrunesDisappearedPersistentSurfaces() {
    var cache = HermesSessionBindingCache(bindings: [
        "A": HermesSessionBinding(
            surfacePersistentID: "A", workspacePersistentID: "W",
            machine: "mac-air", profile: "default", sessionID: "one",
            matchMethod: "exact-title", resolvedAt: .distantPast
        ),
        "B": HermesSessionBinding(
            surfacePersistentID: "B", workspacePersistentID: "W",
            machine: "mac-air", profile: "default", sessionID: "two",
            matchMethod: "snippet", resolvedAt: .distantPast
        ),
    ])

    cache.retain(surfacePersistentIDs: ["B"])

    #expect(cache.bindings.keys.sorted() == ["B"])
}

@Test func decodesLatestCompleteJarvisTurnAndBinding() throws {
    let json = """
    {
      "schema_version":"1.0",
      "provenance":{"machine":"mac-mini","hermes_profile":"default"},
      "match":{"status":"matched","method":"snippet","candidates":[]},
      "session":{"id":"20260805_abc123","title":"Fix routing"},
      "turns":[
        {"state":"complete","first_message_id":10,"last_message_id":13,"events":[
          {"message_id":10,"type":"user","content":{"preview":"Please fix routing","truncated":false}},
          {"message_id":11,"type":"tool_result","name":"terminal","content":{"preview":"ok","truncated":false}},
          {"message_id":13,"type":"assistant","content":{"preview":"Routing is fixed and verified.","truncated":false}}
        ]},
        {"state":"in_progress","first_message_id":14,"last_message_id":14,"events":[
          {"message_id":14,"type":"user","content":{"preview":"One more thing","truncated":false}}
        ]}
      ]
    }
    """
    let envelope = try JSONDecoder().decode(JarvisBridgeEnvelope.self, from: Data(json.utf8))
    let lane = LaneSnapshot(
        id: "surface:1", persistentID: "SURFACE-UUID", title: "Lane", state: .ready,
        workspaceID: "workspace:6", workspacePersistentID: "WORKSPACE-UUID",
        machine: "mac-mini"
    )

    let binding = envelope.binding(for: lane, resolvedAt: Date(timeIntervalSince1970: 100))
    #expect(binding?.sessionID == "20260805_abc123")
    #expect(binding?.matchMethod == "snippet")
    #expect(envelope.latestCompleteTurn?.userText == "Please fix routing")
    #expect(envelope.latestCompleteTurn?.assistantText == "Routing is fixed and verified.")
    #expect(envelope.latestCompleteTurn?.toolNames == ["terminal"])
}

@Test func refusesBindingWhenEnvelopeProvenanceConflicts() throws {
    let json = """
    {"schema_version":"1.0","provenance":{"machine":"mac-air","hermes_profile":"default"},
     "match":{"status":"matched","method":"exact-title"},"session":{"id":"wrong"},"turns":[]}
    """
    let envelope = try JSONDecoder().decode(JarvisBridgeEnvelope.self, from: Data(json.utf8))
    let remoteLane = LaneSnapshot(
        id: "surface:1", persistentID: "S", title: "Lane", state: .ready,
        workspacePersistentID: "W", machine: "mac-mini"
    )

    #expect(envelope.binding(for: remoteLane, resolvedAt: .now) == nil)
}
