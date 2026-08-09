import Foundation
import Testing
@testable import NextUp

@Test func boundedProbeInputReadsThroughEOFWithoutWaitingForDeadline() throws {
    let pipe = Pipe()
    pipe.fileHandleForWriting.write(Data("opaque".utf8))
    try pipe.fileHandleForWriting.close()

    let data = try BoundedProbeInput.read(
        maximumBytes: 32,
        fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
        deadlineMilliseconds: 500
    )

    #expect(String(data: data, encoding: .utf8) == "opaque")
}

@Test func boundedProbeInputTimesOutWhenWriterHoldsEmptyPipeOpen() throws {
    let pipe = Pipe()
    defer {
        try? pipe.fileHandleForWriting.close()
        try? pipe.fileHandleForReading.close()
    }
    let started = ContinuousClock.now

    #expect(throws: BoundedProbeInput.Error.deadlineExceeded) {
        _ = try BoundedProbeInput.read(
            maximumBytes: 32,
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            deadlineMilliseconds: 100
        )
    }
    #expect(started.duration(to: .now) < .seconds(1))
}

@Test func boundedProbeInputRejectsMoreThanMaximumBytes() throws {
    let pipe = Pipe()
    pipe.fileHandleForWriting.write(Data(repeating: 0x78, count: 33))
    try pipe.fileHandleForWriting.close()

    #expect(throws: BoundedProbeInput.Error.inputTooLarge) {
        _ = try BoundedProbeInput.read(
            maximumBytes: 32,
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            deadlineMilliseconds: 500
        )
    }
}
