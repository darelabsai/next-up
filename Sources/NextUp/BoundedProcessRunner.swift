import Foundation
import Darwin

enum BoundedProcessRunnerError: Error, Equatable {
    case timedOut
    case standardOutputExceededLimit
    case outputDrainTimedOut
}

struct BoundedProcessResult: Sendable {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32
}

struct BoundedProcessRunner: Sendable {
    enum StdinWriterLifecycle: Sendable {
        case started
        case finished
    }

    private let stdinWriterLifecycle: (@Sendable (StdinWriterLifecycle) -> Void)?

    init(
        stdinWriterLifecycle: (@Sendable (StdinWriterLifecycle) -> Void)? = nil
    ) {
        self.stdinWriterLifecycle = stdinWriterLifecycle
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: Data? = nil,
        deadline: TimeInterval,
        standardOutputLimit: Int = 1_048_576
    ) throws -> BoundedProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let standardOutput = Pipe()
        let standardError = Pipe()
        let standardInputPipe = standardInput.map { _ in Pipe() }
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.standardInput = standardInputPipe

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        try process.run()

        let outputBox = LockedDrainResult()
        let errorBox = LockedDrainResult()
        let drains = DispatchGroup()
        drains.enter()
        Thread.detachNewThread {
            autoreleasepool {
                outputBox.store(drain(
                    standardOutput.fileHandleForReading,
                    retainingAtMost: max(0, standardOutputLimit)
                ))
                drains.leave()
            }
        }
        drains.enter()
        Thread.detachNewThread {
            autoreleasepool {
                errorBox.store(drain(
                    standardError.fileHandleForReading,
                    retainingAtMost: 16_384
                ))
                drains.leave()
            }
        }

        let stdinCancellation = LockedCancellation()
        let stdinWriter = DispatchGroup()
        if let standardInput, let standardInputPipe {
            let writingHandle = standardInputPipe.fileHandleForWriting
            let descriptor = writingHandle.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            stdinWriter.enter()
            Thread.detachNewThread {
                autoreleasepool {
                    stdinWriterLifecycle?(.started)
                    defer {
                        try? writingHandle.close()
                        stdinWriterLifecycle?(.finished)
                        stdinWriter.leave()
                    }
                    write(
                        standardInput,
                        to: descriptor,
                        untilCancelled: stdinCancellation
                    )
                }
            }
        }

        let completed = terminated.wait(timeout: .now() + max(0, deadline)) == .success
        stdinCancellation.cancel()
        stdinWriter.wait()
        if !completed {
            process.terminate()
            if terminated.wait(timeout: .now() + 0.25) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                terminated.wait()
            }
        }
        let initialDrain = drains.wait(timeout: .now() + 0.1)
        let forcedDrainClose = initialDrain == .timedOut
        if forcedDrainClose {
            try? standardOutput.fileHandleForReading.close()
            try? standardError.fileHandleForReading.close()
        }
        let drainsCompleted = initialDrain == .success
            || drains.wait(timeout: .now() + 0.1) == .success

        if !completed {
            throw BoundedProcessRunnerError.timedOut
        }
        if forcedDrainClose || !drainsCompleted {
            throw BoundedProcessRunnerError.outputDrainTimedOut
        }
        if outputBox.value.exceededLimit {
            throw BoundedProcessRunnerError.standardOutputExceededLimit
        }

        return BoundedProcessResult(
            standardOutput: outputBox.value.data,
            standardError: errorBox.value.data,
            terminationStatus: process.terminationStatus
        )
    }
}

private func write(
    _ data: Data,
    to descriptor: Int32,
    untilCancelled cancellation: LockedCancellation
) {
    data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count, !cancellation.isCancelled {
            var writable = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let pollResult = poll(&writable, 1, 10)
            if pollResult < 0 {
                if errno == EINTR { continue }
                return
            }
            if pollResult == 0 { continue }
            if writable.revents & Int16(POLLOUT) == 0 { return }

            let written = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                bytes.count - offset
            )
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR || errno == EAGAIN {
                continue
            } else {
                return
            }
        }
    }
}

private func drain(
    _ handle: FileHandle,
    retainingAtMost limit: Int
) -> DrainResult {
    var retained = Data()
    var exceededLimit = false
    while true {
        let chunk = handle.availableData
        guard !chunk.isEmpty else {
            return DrainResult(data: retained, exceededLimit: exceededLimit)
        }
        let remaining = max(0, limit - retained.count)
        if remaining > 0 {
            retained.append(chunk.prefix(remaining))
        }
        if chunk.count > remaining {
            exceededLimit = true
        }
    }
}

private struct DrainResult: Sendable {
    let data: Data
    let exceededLimit: Bool
}

private final class LockedDrainResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = DrainResult(data: Data(), exceededLimit: false)

    var value: DrainResult {
        lock.withLock { storage }
    }

    func store(_ result: DrainResult) {
        lock.withLock { storage = result }
    }
}

private final class LockedCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
