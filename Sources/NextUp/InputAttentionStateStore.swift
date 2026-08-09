import Foundation
import NextUpCore

struct InputAttentionStateStore: Sendable {
    let url: URL

    func load() -> InputAttentionTracker {
        guard let data = try? Data(contentsOf: url),
              let tracker = try? JSONDecoder().decode(InputAttentionTracker.self, from: data) else {
            return InputAttentionTracker()
        }
        return tracker
    }

    func save(_ tracker: InputAttentionTracker) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(tracker)
        try data.write(to: url, options: .atomic)
    }
}
