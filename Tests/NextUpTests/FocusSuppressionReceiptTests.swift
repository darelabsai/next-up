import Foundation
import Testing
import NextUpCore
@testable import NextUp

private let receiptRoute = CMUXNavigationTarget(
    windowID: "window-id", windowRef: "window-ref-secret",
    workspaceID: "workspace-id", workspaceRef: "workspace-ref-secret",
    paneID: "pane-id", paneRef: "pane-ref-secret",
    surfaceID: "surface-id", surfaceRef: "surface-ref-secret"
)

@Test func receiptCodingContainsOnlyPrivacySafeOrderedFields() throws {
    let epoch = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let receipt = try #require(FocusSuppressionReceipt(
        identity: FocusAlertIdentity(kind: .completion, laneID: "opaque-lane", navigationTarget: receiptRoute),
        processEpoch: epoch,
        proposedSequence: 7,
        observationTimestamp: Date(timeIntervalSince1970: 123)
    ))

    let data = try JSONEncoder().encode(receipt)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(Set(object.keys) == [
        "kind", "opaqueLaneID", "windowID", "workspaceID", "paneID", "surfaceID",
        "processEpoch", "proposedSequence", "observationTimestamp",
        "nativeRequestScheduled", "voiceScheduled",
    ])
    #expect(object["nativeRequestScheduled"] as? Bool == false)
    #expect(object["voiceScheduled"] as? Bool == false)
    let json = String(decoding: data, as: UTF8.self)
    #expect(!json.contains("ref-secret"))
    #expect(!json.contains("title"))
    #expect(!json.contains("summary"))
}

@Test func pollReceiptStoreAdvancesSequenceAndBaselineGenerationByCommittedKind() throws {
    let url = temporaryReceiptURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let epoch = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let store = PollReceiptStateStore(url: url, processEpoch: epoch)
    var state = store.load()
    let completion = FocusAlertIdentity(kind: .completion, laneID: "completion", navigationTarget: receiptRoute)
    let input = FocusAlertIdentity(kind: .inputRequired, laneID: "input", navigationTarget: receiptRoute)

    state = try store.commit(
        from: state, pollKind: .baseline, suppressions: [completion],
        observationTimestamp: Date(timeIntervalSince1970: 100)
    )
    #expect(state.appliedPollSequence == 1)
    #expect(state.appliedBaselineGeneration == 1)
    #expect(state.latestReceipts[.completion]?.opaqueLaneID == "completion")

    state = try store.commit(
        from: state, pollKind: .wake, suppressions: [input],
        observationTimestamp: Date(timeIntervalSince1970: 101)
    )
    #expect(state.appliedPollSequence == 2)
    #expect(state.appliedBaselineGeneration == 1)
    #expect(state.latestReceipts[.completion]?.opaqueLaneID == "completion")
    #expect(state.latestReceipts[.inputRequired]?.opaqueLaneID == "input")

    state = try store.commit(
        from: state, pollKind: .retry, suppressions: [], observationTimestamp: nil
    )
    #expect(state.appliedPollSequence == 3)
    #expect(state.appliedBaselineGeneration == 1)
    #expect(store.load().appliedPollSequence == 3)
}

@Test func failedReceiptWritePublishesNeitherCountersNorClaimedSuppression() throws {
    enum Expected: Error { case write }
    let url = temporaryReceiptURL()
    let epoch = UUID()
    let store = PollReceiptStateStore(
        url: url,
        processEpoch: epoch,
        atomicWriter: { _, _ in throw Expected.write }
    )
    let original = store.load()

    #expect(throws: Expected.self) {
        _ = try store.commit(
            from: original,
            pollKind: .baseline,
            suppressions: [FocusAlertIdentity(
                kind: .completion, laneID: "lane", navigationTarget: receiptRoute
            )],
            observationTimestamp: Date(timeIntervalSince1970: 100)
        )
    }
    #expect(original.appliedPollSequence == 0)
    #expect(original.appliedBaselineGeneration == 0)
    #expect(original.latestReceipts.isEmpty)
}

@Test func processEpochChangesPerLaunchWhilePersistedCountersAndReceiptsSurvive() throws {
    let url = temporaryReceiptURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let firstEpoch = UUID()
    let firstStore = PollReceiptStateStore(url: url, processEpoch: firstEpoch)
    let committed = try firstStore.commit(
        from: firstStore.load(), pollKind: .baseline,
        suppressions: [FocusAlertIdentity(kind: .completion, laneID: "lane", navigationTarget: receiptRoute)],
        observationTimestamp: Date(timeIntervalSince1970: 100)
    )
    let secondEpoch = UUID()
    let restarted = PollReceiptStateStore(url: url, processEpoch: secondEpoch).load()

    #expect(committed.processEpoch == firstEpoch)
    #expect(restarted.processEpoch == secondEpoch)
    #expect(restarted.appliedPollSequence == 1)
    #expect(restarted.appliedBaselineGeneration == 1)
    #expect(restarted.latestReceipts[.completion]?.processEpoch == firstEpoch)
}

private func temporaryReceiptURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("nextup-poll-receipt-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("poll-receipt.json")
}
