import Foundation
import NextUpCore
import Darwin

/// The single durable authority for alert state and suppression acceptance.
/// Legacy state files are mirrors only; restart and probes read this transaction.
struct WatcherTransactionState: Codable, Equatable, Sendable {
    var laneMonitorState: LaneMonitorState
    var inputAttentionTracker: InputAttentionTracker
    var pollReceiptState: PollReceiptState

    init(
        laneMonitorState: LaneMonitorState = LaneMonitorState(),
        inputAttentionTracker: InputAttentionTracker = InputAttentionTracker(),
        pollReceiptState: PollReceiptState
    ) {
        self.laneMonitorState = laneMonitorState
        self.inputAttentionTracker = inputAttentionTracker
        self.pollReceiptState = pollReceiptState
    }
}

struct WatcherTransactionStateStore: Sendable {
    typealias AtomicWriter = @Sendable (Data, URL) throws -> Void

    let url: URL
    let processEpoch: UUID
    private let atomicWriter: AtomicWriter

    init(
        url: URL,
        processEpoch: UUID = UUID(),
        atomicWriter: @escaping AtomicWriter = { data, url in
            let directory = url.deletingLastPathComponent()
            var canonicalParentBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard Darwin.realpath(
                directory.deletingLastPathComponent().path,
                &canonicalParentBuffer
            ) != nil else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let terminator = canonicalParentBuffer.firstIndex(of: 0) ?? canonicalParentBuffer.endIndex
            let canonicalParentPath = String(
                decoding: canonicalParentBuffer[..<terminator].map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            let canonicalParent = URL(fileURLWithPath: canonicalParentPath, isDirectory: true)
            let anchoredDirectory = canonicalParent.appendingPathComponent(directory.lastPathComponent)
            let components = anchoredDirectory.pathComponents
            guard components.first == "/", let finalComponent = components.last else {
                throw POSIXError(.EINVAL)
            }
            var parentDescriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard parentDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            do {
                for component in components.dropFirst().dropLast() {
                    var nextDescriptor = Darwin.openat(
                        parentDescriptor,
                        component,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                    if nextDescriptor < 0, errno == ENOENT {
                        guard Darwin.mkdirat(parentDescriptor, component, mode_t(0o700)) == 0
                                || errno == EEXIST else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        nextDescriptor = Darwin.openat(
                            parentDescriptor,
                            component,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                    guard nextDescriptor >= 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    Darwin.close(parentDescriptor)
                    parentDescriptor = nextDescriptor
                }
                guard Darwin.mkdirat(parentDescriptor, finalComponent, mode_t(0o700)) == 0
                        || errno == EEXIST else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } catch {
                Darwin.close(parentDescriptor)
                throw error
            }
            let directoryDescriptor = Darwin.openat(
                parentDescriptor,
                finalComponent,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            Darwin.close(parentDescriptor)
            guard directoryDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { Darwin.close(directoryDescriptor) }
            var privateDirectory = stat()
            guard Darwin.fstat(directoryDescriptor, &privateDirectory) == 0,
                  privateDirectory.st_uid == Darwin.getuid(),
                  Darwin.fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            func validateDirectoryIdentity() throws {
                var bound = stat()
                var current = stat()
                guard Darwin.fstat(directoryDescriptor, &bound) == 0,
                      Darwin.lstat(directory.path, &current) == 0,
                      bound.st_dev == current.st_dev,
                      bound.st_ino == current.st_ino else {
                    throw POSIXError(.ESTALE)
                }
            }
            func synchronizeDirectory() throws {
                if Darwin.fcntl(directoryDescriptor, F_FULLFSYNC) == -1,
                   Darwin.fsync(directoryDescriptor) == -1 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            try validateDirectoryIdentity()
            let temporaryName = ".watcher-transaction.\(UUID().uuidString).tmp"
            let backupName = ".watcher-transaction.\(UUID().uuidString).previous"
            var published = false
            var backupCreated = false
            defer {
                if !published {
                    _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
                }
                if backupCreated {
                    _ = Darwin.unlinkat(directoryDescriptor, backupName, 0)
                }
            }
            let temporaryDescriptor = Darwin.openat(
                directoryDescriptor,
                temporaryName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
            guard temporaryDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard Darwin.fchmod(temporaryDescriptor, mode_t(0o600)) == 0 else {
                Darwin.close(temporaryDescriptor)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: temporaryDescriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if Darwin.linkat(
                directoryDescriptor,
                url.lastPathComponent,
                directoryDescriptor,
                backupName,
                0
            ) == 0 {
                backupCreated = true
                try synchronizeDirectory()
            } else if errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard Darwin.renameat(
                directoryDescriptor,
                temporaryName,
                directoryDescriptor,
                url.lastPathComponent
            ) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            do {
                try synchronizeDirectory()
                try validateDirectoryIdentity()
            } catch {
                let restored: Bool
                if backupCreated {
                    restored = Darwin.renameat(
                        directoryDescriptor,
                        backupName,
                        directoryDescriptor,
                        url.lastPathComponent
                    ) == 0
                    if restored {
                        backupCreated = false
                    }
                } else {
                    restored = Darwin.unlinkat(directoryDescriptor, url.lastPathComponent, 0) == 0
                        || errno == ENOENT
                }
                guard restored else {
                    Darwin.abort()
                }
                do {
                    try synchronizeDirectory()
                    try validateDirectoryIdentity()
                } catch {
                    Darwin.abort()
                }
                throw error
            }
            published = true
            if backupCreated,
               Darwin.unlinkat(directoryDescriptor, backupName, 0) == 0 {
                backupCreated = false
                try? synchronizeDirectory()
            }
        }
    ) {
        self.url = url
        self.processEpoch = processEpoch
        self.atomicWriter = atomicWriter
    }

    func load(
        legacyLaneMonitorState: LaneMonitorState = LaneMonitorState(),
        legacyInputAttentionTracker: InputAttentionTracker = InputAttentionTracker()
    ) -> WatcherTransactionState {
        let restored: WatcherTransactionState
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(WatcherTransactionState.self, from: data) {
            restored = decoded
        } else {
            restored = WatcherTransactionState(
                laneMonitorState: legacyLaneMonitorState,
                inputAttentionTracker: legacyInputAttentionTracker,
                pollReceiptState: PollReceiptState(processEpoch: processEpoch)
            )
        }
        var launched = restored
        launched.pollReceiptState.processEpoch = processEpoch
        return launched
    }

    /// Conservatively makes an acknowledgement durable before asynchronous work.
    /// Counters and receipts do not advance until the poll itself commits.
    func commitAcknowledgement(
        from current: WatcherTransactionState,
        laneMonitorState: LaneMonitorState,
        inputAttentionTracker: InputAttentionTracker
    ) throws -> WatcherTransactionState {
        var proposed = current
        proposed.laneMonitorState = laneMonitorState
        proposed.inputAttentionTracker = inputAttentionTracker
        proposed.pollReceiptState.processEpoch = processEpoch
        try write(proposed)
        return proposed
    }

    /// Atomically publishes poll state, input state, counters, and any receipts.
    func commitPoll(
        from current: WatcherTransactionState,
        pollKind: WatcherPollKind,
        laneMonitorState: LaneMonitorState,
        inputAttentionTracker: InputAttentionTracker,
        suppressionPlans: [FocusSuppressionPlan]
    ) throws -> WatcherTransactionState {
        var proposed = current
        proposed.laneMonitorState = laneMonitorState
        proposed.inputAttentionTracker = inputAttentionTracker
        proposed.pollReceiptState.processEpoch = processEpoch
        proposed.pollReceiptState.appliedPollSequence += 1
        if pollKind == .baseline {
            proposed.pollReceiptState.appliedBaselineGeneration += 1
        }
        for plan in suppressionPlans where !plan.suppressions.isEmpty {
            guard let observationTimestamp = plan.observationTimestamp else {
                throw PollReceiptStateStore.ReceiptError.missingObservationTimestamp
            }
            for identity in plan.suppressions.sorted(by: Self.receiptOrder) {
                guard let receipt = FocusSuppressionReceipt(
                    identity: identity,
                    processEpoch: processEpoch,
                    proposedSequence: proposed.pollReceiptState.appliedPollSequence,
                    observationTimestamp: observationTimestamp
                ) else { continue }
                proposed.pollReceiptState.latestReceipts[identity.kind] = receipt
            }
        }
        try write(proposed)
        return proposed
    }

    private func write(_ state: WatcherTransactionState) throws {
        try atomicWriter(try JSONEncoder().encode(state), url)
    }

    private static func receiptOrder(_ lhs: FocusAlertIdentity, _ rhs: FocusAlertIdentity) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.laneID < rhs.laneID
    }
}
