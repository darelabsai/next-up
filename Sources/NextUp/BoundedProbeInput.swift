import Darwin
import Foundation

enum BoundedProbeInput {
    enum Error: Swift.Error, Equatable {
        case deadlineExceeded
        case inputTooLarge
        case readFailed
    }

    static func read(
        maximumBytes: Int,
        fileDescriptor: Int32 = STDIN_FILENO,
        deadlineMilliseconds: Int = 2_000
    ) throws -> Data {
        precondition(maximumBytes > 0)
        precondition(deadlineMilliseconds > 0)

        let start = DispatchTime.now().uptimeNanoseconds
        let budget = UInt64(deadlineMilliseconds) * 1_000_000
        let deadline = start.addingReportingOverflow(budget)
        guard !deadline.overflow else { throw Error.deadlineExceeded }

        var result = Data()
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.partialValue else { throw Error.deadlineExceeded }
            let remainingNanoseconds = deadline.partialValue - now
            let remainingMilliseconds = max(1, min(
                UInt64(Int32.max),
                (remainingNanoseconds + 999_999) / 1_000_000
            ))
            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let readiness = poll(&descriptor, 1, Int32(remainingMilliseconds))
            if readiness == 0 { throw Error.deadlineExceeded }
            if readiness < 0 {
                if errno == EINTR { continue }
                throw Error.readFailed
            }
            if descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 {
                throw Error.readFailed
            }

            let capacity = min(4_096, maximumBytes + 1 - result.count)
            var buffer = [UInt8](repeating: 0, count: capacity)
            let count = Darwin.read(fileDescriptor, &buffer, capacity)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw Error.readFailed
            }
            result.append(buffer, count: count)
            if result.count > maximumBytes { throw Error.inputTooLarge }
        }
    }
}
