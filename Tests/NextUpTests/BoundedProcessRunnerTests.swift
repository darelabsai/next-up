import Foundation
import Testing
import Darwin
@testable import NextUp

private final class StdinWriterLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BoundedProcessRunner.StdinWriterLifecycle] = []

    var events: [BoundedProcessRunner.StdinWriterLifecycle] {
        lock.withLock { storage }
    }

    func record(_ event: BoundedProcessRunner.StdinWriterLifecycle) {
        lock.withLock { storage.append(event) }
    }
}

@Test func boundedProcessRunnerReturnsExactOutputAndExitStatus() throws {
    let runner = BoundedProcessRunner()
    let result = try runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf exact-out; printf exact-error >&2; exit 7"],
        deadline: 1
    )

    #expect(result.standardOutput == Data("exact-out".utf8))
    #expect(result.standardError == Data("exact-error".utf8))
    #expect(result.terminationStatus == 7)
}

@Test func boundedProcessRunnerTimesOutPromptly() {
    let runner = BoundedProcessRunner()
    let started = Date()

    #expect(throws: BoundedProcessRunnerError.timedOut) {
        _ = try runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["2"],
            deadline: 0.05
        )
    }
    #expect(Date().timeIntervalSince(started) < 1)
}

@Test func boundedProcessRunnerKillsAndReapsProcessIgnoringTermination() throws {
    let pidFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("next-up-runner-\(UUID().uuidString).pid")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let source = """
    import os, signal, time
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    open(\(String(reflecting: pidFile.path)), 'w').write(str(os.getpid()))
    time.sleep(10)
    """

    #expect(throws: BoundedProcessRunnerError.timedOut) {
        _ = try BoundedProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", source],
            deadline: 1
        )
    }

    let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
    errno = 0
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
}

@Test func boundedProcessRunnerCapsRetainedStandardErrorWhileDraining() throws {
    let result = try BoundedProcessRunner().run(
        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: ["-c", "import sys; sys.stderr.write('x' * 100_000)"],
        deadline: 1
    )

    #expect(result.terminationStatus == 0)
    #expect(result.standardError.count == 16_384)
}

@Test func boundedProcessRunnerFailsClosedAfterDrainingOversizedStandardOutput() {
    #expect(throws: BoundedProcessRunnerError.standardOutputExceededLimit) {
        _ = try BoundedProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import sys; sys.stdout.write('x' * 100_000)"],
            deadline: 1,
            standardOutputLimit: 16_384
        )
    }
}

@Test func boundedProcessRunnerTimeoutIsNotHeldOpenByDescendantPipes() {
    let started = Date()

    #expect(throws: BoundedProcessRunnerError.timedOut) {
        _ = try BoundedProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 2 & wait"],
            deadline: 0.05
        )
    }
    #expect(Date().timeIntervalSince(started) < 1)
}

@Test func boundedProcessRunnerTimeoutIsNotHeldOpenByDetachedDescendantPipes() {
    let started = Date()

    #expect(throws: BoundedProcessRunnerError.timedOut) {
        _ = try BoundedProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [
                "-c",
                "import os, time; pid=os.fork(); "
                    + "(os.setsid(), time.sleep(2)) if pid == 0 else time.sleep(2)",
            ],
            deadline: 0.05
        )
    }

    #expect(Date().timeIntervalSince(started) < 1)
}

@Test func boundedProcessRunnerFailsClosedWhenDetachedDescendantOutlivesNormalExit() {
    let started = Date()

    #expect(throws: BoundedProcessRunnerError.outputDrainTimedOut) {
        _ = try BoundedProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [
                "-c",
                "import os, time; pid=os.fork(); "
                    + "(os.setsid(), time.sleep(2)) if pid == 0 else None",
            ],
            deadline: 1
        )
    }

    #expect(Date().timeIntervalSince(started) < 1)
}

@Test func boundedProcessRunnerDrainsSimultaneousOutputBeyondPipeCapacity() throws {
    let result = try BoundedProcessRunner().run(
        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: [
            "-c",
            "import os, threading; a=threading.Thread(target=lambda: os.write(1,b'o'*200000)); b=threading.Thread(target=lambda: os.write(2,b'e'*200000)); a.start(); b.start(); a.join(); b.join()",
        ],
        deadline: 2
    )

    #expect(result.terminationStatus == 0)
    #expect(result.standardOutput == Data(repeating: 0x6f, count: 200_000))
    #expect(result.standardError == Data(repeating: 0x65, count: 16_384))
}

@Test func boundedProcessRunnerWritesStdinWhileConcurrentlyDrainingBothOutputs() throws {
    let input = Data(repeating: 0x69, count: 200_000)
    let result = try BoundedProcessRunner().run(
        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: [
            "-c",
            "import os, sys, threading; "
                + "a=threading.Thread(target=lambda: os.write(1,b'o'*200000)); "
                + "b=threading.Thread(target=lambda: os.write(2,b'e'*200000)); "
                + "a.start(); b.start(); data=sys.stdin.buffer.read(); a.join(); b.join(); "
                + "os.write(1, ('\\n%d' % len(data)).encode())",
        ],
        standardInput: input,
        deadline: 2
    )

    #expect(result.terminationStatus == 0)
    #expect(result.standardOutput == Data(repeating: 0x6f, count: 200_000) + Data("\n200000".utf8))
    #expect(result.standardError == Data(repeating: 0x65, count: 16_384))
}

@Test func boundedProcessRunnerJoinsCanceledWriterWhenDescendantInheritsStdin() throws {
    let lifecycle = StdinWriterLifecycleRecorder()
    let runner = BoundedProcessRunner(stdinWriterLifecycle: lifecycle.record)
    let source = """
    import os, time
    pid = os.fork()
    if pid == 0:
        os.setsid()
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, 1)
        os.dup2(devnull, 2)
        time.sleep(2)
        os._exit(0)
    time.sleep(0.1)
    """
    let started = Date()

    let result = try runner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: ["-c", source],
        standardInput: Data(repeating: 0x69, count: 4_000_000),
        deadline: 1
    )

    #expect(result.terminationStatus == 0)
    #expect(Date().timeIntervalSince(started) < 1)
    #expect(lifecycle.events == [.started, .finished])
}

@Test func boundedProcessRunnerTerminatesAndReapsOrdinaryTimeout() throws {
    let pidFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("next-up-runner-ordinary-\(UUID().uuidString).pid")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let source = """
    import os, time
    open(\(String(reflecting: pidFile.path)), 'w').write(str(os.getpid()))
    time.sleep(10)
    """

    #expect(throws: BoundedProcessRunnerError.timedOut) {
        _ = try BoundedProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", source],
            deadline: 0.15
        )
    }

    let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
    errno = 0
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
}
