import Foundation
import NextUpCore

enum PendingStateProbe {
    struct Payload: Codable, Equatable, Sendable {
        let pending: Bool
        let announcementCount: Int?
        let lastAnnouncedAtUnixMilliseconds: Int64?
    }

    enum ProbeError: Error {
        case emptyLaneID
    }

    static func read(laneID: String, transactionStateURL: URL) throws -> Payload {
        guard !laneID.isEmpty else { throw ProbeError.emptyLaneID }
        guard FileManager.default.fileExists(atPath: transactionStateURL.path) else {
            return Payload(
                pending: false,
                announcementCount: nil,
                lastAnnouncedAtUnixMilliseconds: nil
            )
        }
        let transaction = try JSONDecoder().decode(
            WatcherTransactionState.self,
            from: Data(contentsOf: transactionStateURL)
        )
        let state = transaction.laneMonitorState
        guard let completion = state.pending.first(where: { $0.laneID == laneID }) else {
            return Payload(
                pending: false,
                announcementCount: nil,
                lastAnnouncedAtUnixMilliseconds: nil
            )
        }
        return Payload(
            pending: true,
            announcementCount: completion.announcementCount,
            lastAnnouncedAtUnixMilliseconds: completion.lastAnnouncedAt.map {
                Int64(($0.timeIntervalSince1970 * 1_000).rounded())
            }
        )
    }
}
