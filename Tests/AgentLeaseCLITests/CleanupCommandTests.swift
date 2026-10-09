import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("agentlease cleanup", .serialized)
struct CleanupCommandTests {
    @Test("An exhausted positive registry budget times out, while explicit zero retains its immediate probe", arguments: ["run", "exec"])
    func positiveBudgetIsNotImmediateProbe(mode: String) async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let childMarker = fixture.parent.appendingPathComponent("budget-child-started")
        let command = ["--", "/usr/bin/touch", childMarker.path]
        let expired = try fixture.agentLease([
            mode, "--resource", "cleanup:budget", "--wait-seconds", "0.000000001",
        ] + command, environment: ["AGENTLEASE_AUTO_CLEANUP": "0"])
        defer { terminate(expired.process) }
        try await waitForProcessExit(expired.process)
        #expect(expired.process.terminationStatus == 75, "⚠️ \(expired.errorText())")
        #expect(!FileManager.default.fileExists(atPath: childMarker.path))

        let immediate = try fixture.agentLease([
            mode, "--resource", "cleanup:budget", "--wait-seconds", "0",
        ] + command, environment: ["AGENTLEASE_AUTO_CLEANUP": "0"])
        defer { terminate(immediate.process) }
        try await waitForProcessExit(immediate.process)
        #expect(immediate.process.terminationStatus == 0, "⚠️ \(immediate.errorText())")
        #expect(FileManager.default.fileExists(atPath: childMarker.path))
    }

    @Test("SIGTERM cancels Run waiting for registry admission while the cleaner still owns its gate")
    func signalDuringRegistryAdmission() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let paths = try AgentLeasePaths.open(selectedRoot: fixture.stateRoot.path)
        let seed = try FileLock(resource: ResourceName("cleanup:seed"), paths: paths)
        seed.release()
        let gatePath = URL(fileURLWithPath: paths.rootPath).appendingPathComponent(RegistryGate.fileName)
        let gate = Darwin.open(gatePath.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try #require(gate >= 0)
        defer { _ = Darwin.close(gate) }
        try #require(flock(gate, LOCK_EX | LOCK_NB) == 0)
        let childMarker = fixture.parent.appendingPathComponent("registry-child-started")
        let contender = try fixture.agentLease([
            "run", "--resource", "cleanup:blocked-admission", "--wait-seconds", "20",
            "--", "/usr/bin/touch", childMarker.path,
        ], environment: ["AGENTLEASE_AUTO_CLEANUP": "0"])
        defer { terminate(contender.process) }
        try await waitForRunSignalRelay(contender)
        #expect(try fixture.readRecords().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: childMarker.path))

        try #require(kill(contender.process.processIdentifier, SIGTERM) == 0)
        try await waitForProcessExit(contender.process, timeout: .seconds(3))
        #expect(contender.process.terminationReason == .exit)
        #expect(contender.process.terminationStatus == 143, "⚠️ \(contender.errorText())")
        #expect(!FileManager.default.fileExists(atPath: childMarker.path))
        #expect(try fixture.readRecords().isEmpty)
        let independentDescriptor = Darwin.open(gatePath.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try #require(independentDescriptor >= 0)
        defer { _ = Darwin.close(independentDescriptor) }
        let stillHeld = flock(independentDescriptor, LOCK_SH | LOCK_NB)
        let lockError = errno
        #expect(stillHeld == -1)
        #expect(lockError == EWOULDBLOCK || lockError == EAGAIN)
    }

    @Test("Default preview reports eligibility without mutation; execute honors digest, path, and run keep flags")
    func previewExecuteAndEvidenceKeep() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let paths = try AgentLeasePaths.open(selectedRoot: fixture.stateRoot.path)
        let retired = try makeOldCleanupLock("cleanup:retired", paths: paths)
        let digestResource = try ResourceName("cleanup:keep-digest")
        let digestKept = try makeOldCleanupLock(digestResource.value, paths: paths)
        let pathKept = try makeOldCleanupLock("cleanup:keep-path", paths: paths)
        let oldRecord = try makeOldCleanupRecord(resources: ["cleanup:record"], fixture: fixture, paths: paths)
        let keptRecord = try makeOldCleanupRecord(resources: ["cleanup:kept-record"], fixture: fixture, paths: paths)
        let keepArguments = [
            "--keep-lock-digest", digestResource.lockDigest,
            "--keep-lock-path", pathKept.path,
            "--keep-run-id", keptRecord.deletingPathExtension().lastPathComponent,
        ]

        let preview = try fixture.agentLease(["cleanup", "--json"] + keepArguments)
        defer { terminate(preview.process) }
        let previewReport = try await cleanupReport(preview)
        #expect(!previewReport.execute)
        #expect(previewReport.eligibleCount == 2)
        #expect(previewReport.removedCount == 0)
        for url in [retired, digestKept, pathKept, oldRecord, keptRecord] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        let execute = try fixture.agentLease(["cleanup", "--execute", "--json"] + keepArguments)
        defer { terminate(execute.process) }
        let executeReport = try await cleanupReport(execute)
        #expect(executeReport.execute)
        #expect(executeReport.removedCount == 2)
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        #expect(!FileManager.default.fileExists(atPath: oldRecord.path))
        for url in [digestKept, pathKept, keptRecord] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(FileManager.default.fileExists(
            atPath: fixture.stateRoot.appendingPathComponent(RegistryGate.fileName).path
        ))
    }

    @Test("A descendant inherited descriptor retains the inode and old run after its coordinator exits")
    func descendantHeldResource() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let paths = try AgentLeasePaths.open(selectedRoot: fixture.stateRoot.path)
        let resource = "cleanup:descendant"
        let historical = try makeOldCleanupRecord(resources: [resource], fixture: fixture, paths: paths)
        let helper = try builtExecutable(named: "agentlease-spike-helper")
        let marker = fixture.parent.appendingPathComponent("cleanup-descendant.pid")
        let coordinator = try fixture.agentLease([
            "exec", "--resource", resource, "--", helper,
            "spawn-inheriting-descendant-and-exit", marker.path,
        ], environment: ["AGENTLEASE_AUTO_CLEANUP": "0"])
        defer { terminate(coordinator.process) }
        try await waitForProcessExit(coordinator.process)
        try #require(coordinator.process.terminationStatus == 0)
        try await waitForMarker(marker)
        let descendantPID = try readProcessIdentifier(from: marker)
        defer { _ = kill(descendantPID, SIGKILL) }
        let lock = try fixture.lockPath(resource: resource)
        try ageCleanupFile(lock)
        let originalInode = try cleanupInode(lock)

        let cleanup = try fixture.agentLease(["cleanup", "--execute", "--json"])
        defer { terminate(cleanup.process) }
        let report = try await cleanupReport(cleanup)
        #expect(!report.busy)
        #expect(try cleanupInode(lock) == originalInode)
        #expect(FileManager.default.fileExists(atPath: historical.path))
        let contested = try fixture.helper(["probe-lease", fixture.stateRoot.path, resource])
        defer { terminate(contested.process) }
        try await waitForProcessExit(contested.process)
        #expect(contested.process.terminationStatus == 75, "⚠️ \(contested.errorText())")
        let independent = try fixture.helper(["probe-lease", fixture.stateRoot.path, "cleanup:independent"])
        defer { terminate(independent.process) }
        try await waitForProcessExit(independent.process)
        #expect(independent.process.terminationStatus == 0, "⚠️ \(independent.errorText())")
    }

    @Test("Malformed JSON is preserved and JSON output exposes the failure with exit 70")
    func unsafeRecordFailure() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        _ = try AgentLeasePaths.open(selectedRoot: fixture.stateRoot.path)
        let malformed = fixture.stateRoot.appendingPathComponent("runs/\(UUID().uuidString).json")
        try Data("{".utf8).write(to: malformed)
        try #require(chmod(malformed.path, 0o600) == 0)
        try ageCleanupFile(malformed)
        let original = try Data(contentsOf: malformed)
        let process = try fixture.agentLease(["cleanup", "--execute", "--json"])
        defer { terminate(process.process) }
        let report = try await cleanupReport(process, expectedExit: 70)
        #expect(!report.errors.isEmpty)
        #expect(report.removedCount == 0)
        #expect(try Data(contentsOf: malformed) == original)
    }
}

/// Observe installed signal handling through the kernel, so the test cannot pass
/// by killing Run before it has entered its supervised acquisition lifecycle.
private func waitForRunSignalRelay(_ process: CLIProcess) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        guard process.process.isRunning else {
            throw CLITestError.processExitedEarly(
                status: process.process.terminationStatus,
                output: process.errorText() + process.outputText()
            )
        }
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, process.process.processIdentifier]
        var information = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let result = mib.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, u_int($0.count), &information, &size, nil, 0)
        }
        guard result == 0 else {
            throw CLITestError.systemCall(operation: "sysctl(process signal handling)", errorNumber: errno)
        }
        if size > 0 {
            let installed = [SIGINT, SIGTERM, SIGHUP].allSatisfy { signalNumber in
                sigismember(&information.kp_proc.p_sigignore, signalNumber) == 1
                    || sigismember(&information.kp_proc.p_sigcatch, signalNumber) == 1
            }
            if installed { return }
        }
        try await clock.sleep(for: .milliseconds(20))
    }
    throw CLITestError.markerTimeout("Run signal relay for PID \(process.process.processIdentifier)")
}

private func cleanupReport(_ process: CLIProcess, expectedExit: Int32 = 0) async throws -> CleanupReport {
    try await waitForProcessExit(process.process)
    #expect(process.process.terminationStatus == expectedExit, "⚠️ \(process.errorText())")
    return try JSONDecoder().decode(
        CleanupReport.self,
        from: process.standardOutput.fileHandleForReading.readDataToEndOfFile()
    )
}

private func makeOldCleanupLock(_ value: String, paths: AgentLeasePaths) throws -> URL {
    let resource = try ResourceName(value)
    let lock = try FileLock(resource: resource, paths: paths)
    try #require(try lock.tryAcquire())
    lock.release()
    let url = URL(fileURLWithPath: paths.rootPath).appendingPathComponent("locks/\(resource.lockFileName)")
    try ageCleanupFile(url)
    return url
}

private func makeOldCleanupRecord(
    resources: [String], fixture: CLIFixture, paths: AgentLeasePaths
) throws -> URL {
    let id = UUID().uuidString
    let old = Date().addingTimeInterval(-8 * 86_400)
    let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(old)
    let record = RunRecord(
        runID: id, mode: .run, state: .exited, resources: resources,
        label: nil, bead: nil, coordinatorPID: Int32.max, childPID: nil,
        workingDirectory: fixture.parent.path, executable: "/usr/bin/true",
        resolvedExecutable: "/usr/bin/true", argumentCommitment: String(repeating: "0", count: 64),
        arguments: nil, startedAt: timestamp, finishedAt: timestamp,
        receivedSignal: nil, termination: RunTermination(kind: .exit, value: 0), failure: nil
    )
    try AtomicJSONStore(paths: paths).replace(record, named: "\(id).json")
    let url = fixture.stateRoot.appendingPathComponent("runs/\(id).json")
    try ageCleanupFile(url)
    return url
}

private func ageCleanupFile(_ url: URL) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-8 * 86_400)], ofItemAtPath: url.path
    )
}

private func cleanupInode(_ url: URL) throws -> UInt64 {
    var status = stat()
    try #require(lstat(url.path, &status) == 0)
    return UInt64(status.st_ino)
}
