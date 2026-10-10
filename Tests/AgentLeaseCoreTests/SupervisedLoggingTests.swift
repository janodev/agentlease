@testable import AgentLeaseCore
import Darwin
import Foundation
import Subprocess
import Testing

@Suite("Supervised raw output")
struct SupervisedLoggingTests {
    @Test("Literal arguments, working directory, and separate logs preserve a nonzero exit")
    func literalArgumentsAndWorkingDirectory() async throws {
        let directory = try makeAgentLeaseTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try SupervisedLogFile(directory: directory, name: "stdout")
        let error = try SupervisedLogFile(directory: directory, name: "stderr")
        let literal = "$(false) space ' quote"
        let workingDirectory = try loggingPhysicalPath(directory.path)

        let result = try await SupervisedSubprocess.run(
            executablePath: "/bin/sh",
            arguments: [
                "custom-argv-zero", "-c",
                "printf '%s\\n' \"$0\" \"$1\"; /bin/pwd -P; printf '%s' \"$2\" >&2; exit 23",
                "custom-argv-zero", literal, "separate diagnostic",
            ],
            workingDirectory: workingDirectory,
            standardOutputDescriptor: output.descriptor,
            standardErrorDescriptor: error.descriptor
        )

        #expect(result.termination == .exited(23))
        let actualOutput = try String(contentsOf: output.url, encoding: .utf8)
        let expectedOutput = "custom-argv-zero\n\(literal)\n\(workingDirectory)\n"
        let actualError = try String(contentsOf: error.url, encoding: .utf8)
        #expect(actualOutput == expectedOutput)
        #expect(actualError == "separate diagnostic")
        try output.expectCallerOwnership()
        try error.expectCallerOwnership()
    }

    @Test("A missing working directory is a setup failure rather than a missing executable")
    func missingWorkingDirectoryClassification() async throws {
        let directory = try makeAgentLeaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try SupervisedLogFile(directory: directory, name: "stdout")
        let error = try SupervisedLogFile(directory: directory, name: "stderr")
        let startedMarker = directory.appendingPathComponent("started")

        do {
            _ = try await SupervisedSubprocess.run(
                executablePath: "/bin/sh",
                arguments: ["/bin/sh", "-c", "exit 0"],
                workingDirectory: directory.appendingPathComponent("missing").path,
                standardOutputDescriptor: output.descriptor,
                standardErrorDescriptor: error.descriptor
            ) { _ in
                try Data().write(to: startedMarker)
            }
            Issue.record("Launching with a missing working directory should fail")
        } catch {
            let classified = SupervisedSubprocess.classifyLaunchError(error)
            #expect(classified.exitCode == 70)
            #expect(classified.failure.kind == .spawn)
            #expect(classified.failure.operation == "changeWorkingDirectory")
            #expect(classified.failure.errorNumber == ENOENT)
        }
        #expect(!FileManager.default.fileExists(atPath: startedMarker.path))
        try output.expectCallerOwnership()
        try error.expectCallerOwnership()
    }

    @Test("Binary output larger than capture limits is retained without changing native status")
    func largeBinaryOutput() async throws {
        let directory = try makeAgentLeaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try SupervisedLogFile(directory: directory, name: "stdout")
        let error = try SupervisedLogFile(directory: directory, name: "stderr")
        let outputBytes = Data((0..<524_288).map { UInt8(truncatingIfNeeded: $0) })
        let errorBytes = Data((0..<393_216).map { UInt8(truncatingIfNeeded: 255 - $0) })
        let outputInput = directory.appendingPathComponent("output-input")
        let errorInput = directory.appendingPathComponent("error-input")
        try outputBytes.write(to: outputInput)
        try errorBytes.write(to: errorInput)

        let result = try await SupervisedSubprocess.run(
            executablePath: "/bin/sh",
            arguments: [
                "/bin/sh", "-c", "/bin/cat \"$1\"; /bin/cat \"$2\" >&2; exit 29",
                "fixture", outputInput.path, errorInput.path,
            ],
            standardOutputDescriptor: output.descriptor,
            standardErrorDescriptor: error.descriptor
        )

        #expect(result.termination == .exited(29))
        #expect(try Data(contentsOf: output.url) == outputBytes)
        #expect(try Data(contentsOf: error.url) == errorBytes)
        try output.expectCallerOwnership()
        try error.expectCallerOwnership()
    }

    @Test("Redirected streams preserve signal termination and caller descriptors")
    func signalTermination() async throws {
        let directory = try makeAgentLeaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try SupervisedLogFile(directory: directory, name: "stdout")
        let error = try SupervisedLogFile(directory: directory, name: "stderr")

        let result = try await SupervisedSubprocess.run(
            executablePath: "/bin/sh",
            arguments: ["/bin/sh", "-c", "printf before-signal; kill -TERM $$"],
            standardOutputDescriptor: output.descriptor,
            standardErrorDescriptor: error.descriptor
        )

        #expect(result.termination == .signaled(SIGTERM))
        #expect(try Data(contentsOf: output.url) == Data("before-signal".utf8))
        try output.expectCallerOwnership()
        try error.expectCallerOwnership()
    }

    @Test("A post-spawn callback failure leaves caller output descriptors open")
    func callbackFailurePreservesDescriptors() async throws {
        let directory = try makeAgentLeaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try SupervisedLogFile(directory: directory, name: "stdout")
        let error = try SupervisedLogFile(directory: directory, name: "stderr")

        await #expect(throws: SupervisedLoggingError.callback) {
            try await SupervisedSubprocess.run(
                executablePath: "/bin/sleep",
                arguments: ["/bin/sleep", "30"],
                standardOutputDescriptor: output.descriptor,
                standardErrorDescriptor: error.descriptor
            ) { _ in
                throw SupervisedLoggingError.callback
            }
        }
        try output.expectCallerOwnership()
        try error.expectCallerOwnership()
    }

    @Test("Immediate group cancellation removes a live leader and its signal-ignoring descendant")
    func immediateGroupCancellation() async throws {
        let directory = try makeAgentLeaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try SupervisedLogFile(directory: directory, name: "stdout")
        let error = try SupervisedLogFile(directory: directory, name: "stderr")
        let outputDescriptor = output.descriptor
        let errorDescriptor = error.descriptor
        let descendantMarker = directory.appendingPathComponent("descendant.pid")
        let leaderMarker = directory.appendingPathComponent("leader.pid")
        let readyMarker = directory.appendingPathComponent("descendant-ready")
        let task = Task {
            try await SupervisedSubprocess.run(
                executablePath: "/bin/sh",
                arguments: [
                    "/bin/sh", "-c",
                    "(trap '' INT TERM; printf ready > \"$2\"; exec /bin/sleep 30) & printf '%s\\n' \"$!\" > \"$1\"; wait",
                    "fixture", descendantMarker.path, readyMarker.path,
                ],
                standardOutputDescriptor: outputDescriptor,
                standardErrorDescriptor: errorDescriptor,
                teardownSequence: [
                    .send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero),
                ]
            ) { processIdentifier in
                try "\(processIdentifier)\n".write(to: leaderMarker, atomically: true, encoding: .utf8)
            }
        }
        defer { task.cancel() }
        try await waitForMarker(at: leaderMarker)
        let leader = try readLoggingProcessIdentifier(at: leaderMarker)
        defer { _ = kill(-leader, SIGKILL) }
        try await waitForMarker(at: descendantMarker)
        let descendant = try readLoggingProcessIdentifier(at: descendantMarker)
        defer { _ = kill(descendant, SIGKILL) }
        try await waitForMarker(at: readyMarker)
        #expect(kill(leader, 0) == 0)
        #expect(kill(descendant, 0) == 0)

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        var status: Int32 = 0
        errno = 0
        #expect(waitpid(leader, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            errno = 0
            if kill(-leader, 0) == -1, errno == ESRCH {
                try output.expectCallerOwnership()
                try error.expectCallerOwnership()
                return
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        Issue.record("Cancelled leader's process group still contains its descendant")
    }

    @Test("Cwd and redirected logs keep descendant lock inheritance after the direct child exits")
    func descendantRetainsLease() async throws {
        let directory = try makeAgentLeaseTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try SupervisedLogFile(directory: directory, name: "stdout")
        let error = try SupervisedLogFile(directory: directory, name: "stderr")
        let paths = try AgentLeasePaths.open(selectedRoot: directory.appendingPathComponent("state").path)
        let resource = try ResourceName("logging:descendant")
        let owner = try FileLock(resource: resource, paths: paths)
        defer { owner.release() }
        #expect(try owner.tryAcquire())
        let descriptor = try #require(owner.inheritedDescriptor)
        let marker = directory.appendingPathComponent("descendant.pid")
        let helper = try agentLeaseHelperPath()

        let result = try await SupervisedSubprocess.run(
            executablePath: helper,
            arguments: [helper, "spawn-inheriting-descendant-and-exit", marker.path],
            inheritedDescriptors: [descriptor],
            workingDirectory: directory.path,
            standardOutputDescriptor: output.descriptor,
            standardErrorDescriptor: error.descriptor
        )
        #expect(result.termination == .exited(0))
        try await waitForMarker(at: marker)
        let text = try String(contentsOf: marker, encoding: .utf8)
        let descendant = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { _ = kill(descendant, SIGKILL) }

        #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        owner.release()
        let contender = try FileLock(resource: resource, paths: paths)
        defer { contender.release() }
        #expect(try !contender.tryAcquire())
        try output.expectCallerOwnership()
        try error.expectCallerOwnership()
        #expect(kill(descendant, SIGKILL) == 0)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if try contender.tryAcquire() { return }
            try await clock.sleep(for: .milliseconds(20))
        }
        Issue.record("Descendant exit did not release its inherited lease")
    }
}

private enum SupervisedLoggingError: Error, Equatable {
    case callback
}

private func readLoggingProcessIdentifier(at marker: URL) throws -> Int32 {
    let text = try String(contentsOf: marker, encoding: .utf8)
    return try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
}

private func loggingPhysicalPath(_ path: String) throws -> String {
    guard let resolved = Darwin.realpath(path, nil) else {
        throw AgentLeaseTestError.systemCall("realpath", errno)
    }
    defer { Darwin.free(resolved) }
    return String(cString: resolved)
}

private final class SupervisedLogFile {
    let descriptor: Int32
    let url: URL

    init(directory: URL, name: String) throws {
        url = directory.appendingPathComponent(name)
        descriptor = Darwin.open(
            url.path,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw AgentLeaseTestError.systemCall("open-log", errno)
        }
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    func expectCallerOwnership() throws {
        let flags = fcntl(descriptor, F_GETFD)
        #expect(flags >= 0)
        #expect(flags & FD_CLOEXEC != 0)
        let bytes = Data("parent-append".utf8)
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        #expect(written == bytes.count)
        #expect(try Data(contentsOf: url).suffix(bytes.count) == bytes)
    }
}
