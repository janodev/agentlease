@testable import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("Swift Subprocess integration spike", .serialized)
struct SupervisedSubprocessTests {
    @Test("Null stdin, inherited output, child PID, and session creation")
    func basicSupervisionContract() async throws {
        let helper = try spikeHelperPath()
        let startedProcess = ProcessIdentifierStore()

        let result = try await SupervisedSubprocess.run(
            executablePath: helper,
            arguments: [helper, "check-basics"]
        ) { processIdentifier in
            await startedProcess.set(processIdentifier)
        }

        #expect(result.termination == .exited(0))
        #expect(await startedProcess.get() == result.processIdentifier)
    }

    @Test("Exact argv override preserves a nonzero child result")
    func exactArgumentsAndTermination() async throws {
        let helper = try spikeHelperPath()
        let result = try await SupervisedSubprocess.run(
            executablePath: helper,
            arguments: ["caller-selected-argv-zero", "exit", "23"]
        )

        #expect(result.termination == .exited(23))
    }

    @Test("Spawn actions inherit only selected close-on-exec descriptors")
    func descriptorInheritance() async throws {
        let helper = try spikeHelperPath()
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let lockPath = temporaryDirectory.appendingPathComponent("spike.lock").path
        let openedDescriptor = Darwin.open(
            lockPath,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard openedDescriptor >= 0 else {
            throw TestError.systemCall("open", errno)
        }
        guard flock(openedDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = Darwin.close(openedDescriptor)
            throw TestError.systemCall("flock", lockError)
        }
        let inheritedDescriptor = fcntl(openedDescriptor, F_DUPFD_CLOEXEC, 64)
        _ = Darwin.close(openedDescriptor)
        guard inheritedDescriptor >= 64 else {
            throw TestError.systemCall("fcntl", errno)
        }
        defer { _ = Darwin.close(inheritedDescriptor) }

        let result = try await SupervisedSubprocess.run(
            executablePath: helper,
            arguments: [
                helper,
                "check-descriptor",
                String(inheritedDescriptor),
            ],
            inheritedDescriptors: [inheritedDescriptor]
        )

        #expect(result.termination == .exited(0))
        #expect(fcntl(inheritedDescriptor, F_GETFD) & FD_CLOEXEC != 0)
    }

    @Test("Child signal dispositions reset to defaults")
    func childSignalDisposition() async throws {
        let helper = try spikeHelperPath()
        let previousDisposition = signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, previousDisposition) }

        let result = try await SupervisedSubprocess.run(
            executablePath: helper,
            arguments: [helper, "raise-interrupt"]
        )

        #expect(result.termination == .signaled(SIGINT))
    }

    @Test("Cancellation kills the process group and waits for reaping")
    func cancellationReapsProcessGroup() async throws {
        let helper = try spikeHelperPath()
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let grandchildMarker = temporaryDirectory.appendingPathComponent("grandchild.pid")
        let startedProcess = ProcessIdentifierStore()

        let task = Task {
            try await SupervisedSubprocess.run(
                executablePath: helper,
                arguments: [
                    helper,
                    "spawn-ignoring-grandchild",
                    grandchildMarker.path,
                ]
            ) { processIdentifier in
                await startedProcess.set(processIdentifier)
            }
        }

        let grandchildPID = try await waitForProcessIdentifier(at: grandchildMarker)
        let directChildPID = try #require(await startedProcess.get())
        defer {
            _ = kill(-directChildPID, SIGKILL)
            _ = kill(grandchildPID, SIGKILL)
            task.cancel()
        }

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation unexpectedly returned a process result")
        } catch is CancellationError {
            // Expected after Swift Subprocess completes teardown and reaping.
        } catch {
            Issue.record("Cancellation returned an unexpected error: \(error)")
        }

        var status: Int32 = 0
        errno = 0
        let waitResult = waitpid(directChildPID, &status, WNOHANG)
        #expect(waitResult == -1)
        #expect(errno == ECHILD)
        try await waitForProcessGroupToExit(directChildPID)
    }

    @Test("A child retains the lock after its coordinator is killed")
    func inheritedLockSurvivesCoordinatorSIGKILL() async throws {
        let helper = try spikeHelperPath()
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let lockURL = temporaryDirectory.appendingPathComponent("retained.lock")
        let childMarker = temporaryDirectory.appendingPathComponent("child.pid")

        let coordinator = Process()
        coordinator.executableURL = URL(fileURLWithPath: helper)
        coordinator.arguments = [
            "coordinate-inherited-lock",
            lockURL.path,
            childMarker.path,
        ]
        try coordinator.run()
        let coordinatorPID = coordinator.processIdentifier
        let childPID = try await waitForProcessIdentifier(at: childMarker)
        defer {
            _ = kill(coordinatorPID, SIGKILL)
            _ = kill(childPID, SIGKILL)
        }

        let probeDescriptor = Darwin.open(lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard probeDescriptor >= 0 else {
            throw TestError.systemCall("open", errno)
        }
        defer { _ = Darwin.close(probeDescriptor) }

        guard kill(coordinatorPID, SIGKILL) == 0 else {
            throw TestError.systemCall("kill", errno)
        }
        coordinator.waitUntilExit()

        errno = 0
        #expect(flock(probeDescriptor, LOCK_EX | LOCK_NB) == -1)
        #expect(errno == EWOULDBLOCK || errno == EAGAIN)

        guard kill(childPID, SIGKILL) == 0 else {
            throw TestError.systemCall("kill", errno)
        }
        try await waitForLockAcquisition(probeDescriptor)
    }
}

private actor ProcessIdentifierStore {
    private var value: Int32?

    func get() -> Int32? {
        value
    }

    func set(_ value: Int32) {
        self.value = value
    }
}

private enum TestError: Error {
    case helperNotFound
    case markerTimeout(URL)
    case processGroupTimeout(Int32)
    case systemCall(String, Int32)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("agentlease-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func spikeHelperPath() throws -> String {
    if let configuredPath = ProcessInfo.processInfo.environment["AGENTLEASE_SPIKE_HELPER"],
       access(configuredPath, X_OK) == 0 {
        return configuredPath
    }

    let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let conventionalPath = packageRoot
        .appendingPathComponent(".build/debug/agentlease-spike-helper")
        .path
    if access(conventionalPath, X_OK) == 0 {
        return conventionalPath
    }

    let buildRoot = packageRoot.appendingPathComponent(".build", isDirectory: true)
    if let enumerator = FileManager.default.enumerator(
        at: buildRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsPackageDescendants]
    ) {
        for case let candidate as URL in enumerator
        where candidate.lastPathComponent == "agentlease-spike-helper"
            && access(candidate.path, X_OK) == 0 {
            return candidate.path
        }
    }

    throw TestError.helperNotFound
}

private func waitForProcessIdentifier(
    at marker: URL,
    timeout: Duration = .seconds(5)
) async throws -> Int32 {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if let contents = try? String(contentsOf: marker, encoding: .utf8),
           let processIdentifier = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return processIdentifier
        }
        try await clock.sleep(for: .milliseconds(20))
    }
    throw TestError.markerTimeout(marker)
}

private func waitForProcessGroupToExit(
    _ processGroup: Int32,
    timeout: Duration = .seconds(5)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        errno = 0
        if kill(-processGroup, 0) == -1, errno == ESRCH {
            return
        }
        try await clock.sleep(for: .milliseconds(20))
    }
    throw TestError.processGroupTimeout(processGroup)
}

private func waitForLockAcquisition(
    _ descriptor: Int32,
    timeout: Duration = .seconds(5)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            return
        }
        let lockError = errno
        guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
            throw TestError.systemCall("flock", lockError)
        }
        try await clock.sleep(for: .milliseconds(20))
    }
    throw TestError.systemCall("flock-timeout", ETIMEDOUT)
}
