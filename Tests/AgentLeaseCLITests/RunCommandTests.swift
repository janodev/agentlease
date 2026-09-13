import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("agentlease run", .serialized)
struct RunCommandTests {
    @Test("Preserves argv, child exit status, records, and attached output streams")
    func argumentsRecordsAndOutput() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let child = try fixture.agentLease([
            "run",
            "--resource", "z:last",
            "--resource", "a:first",
            "--label", "record test",
            "--bead", "bead-1",
            "--record-arguments",
            "--",
            "/bin/sh", "-c", "echo child-out; echo child-err >&2; exit 23",
        ])
        child.process.waitUntilExit()

        #expect(child.process.terminationStatus == 23)
        #expect(child.outputText().contains("child-out"))
        #expect(child.errorText().contains("child-err"))
        let record = try #require(fixture.readRecords().first)
        #expect(record.state == .exited)
        #expect(record.resources == ["a:first", "z:last"])
        #expect(record.executable == "/bin/sh")
        #expect(record.arguments == [
            "/bin/sh", "-c", "echo child-out; echo child-err >&2; exit 23",
        ])
        #expect(record.termination == RunTermination(kind: .exit, value: 23))
        #expect(record.finishedAt != nil)

        let probe = try fixture.helper([
            "probe-lease", fixture.stateRoot.path, "a:first", "z:last",
        ])
        probe.process.waitUntilExit()
        #expect(probe.process.terminationStatus == 0, "\(probe.errorText())")
    }

    @Test("Full arguments are absent by default and child stdin is EOF")
    func argumentPrivacyAndNullInput() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let openInput = Pipe()
        let helper = try builtExecutable(named: "agentlease-spike-helper")
        let child = try fixture.agentLease(
            ["run", "--resource", "stdin", "--", helper, "check-basics"],
            standardInput: openInput
        )
        child.process.waitUntilExit()

        #expect(child.process.terminationStatus == 0, "\(child.errorText())")
        let record = try #require(fixture.readRecords().first)
        #expect(record.arguments == nil)
        #expect(record.argumentCommitment == ArgumentCommitment.digest(arguments: [
            helper, "check-basics",
        ]))
    }

    @Test("Reserved environment is overwritten, stale bead is removed, and unrelated values survive")
    func childEnvironment() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let script = "printf '%s|%s|%s|%s|%s' \"$AGENTLEASE_HOME\" \"$AGENTLEASE_RUN_ID\" \"$AGENTLEASE_HELD_RESOURCES\" \"${AGENTLEASE_BEAD_ID-unset}\" \"$UNRELATED\""
        let child = try fixture.agentLease(
            ["run", "--resource", "b", "--resource", "a", "--", "/bin/sh", "-c", script],
            environment: [
                "AGENTLEASE_BEAD_ID": "stale",
                "AGENTLEASE_RUN_ID": "stale",
                "UNRELATED": "kept",
            ]
        )
        child.process.waitUntilExit()

        #expect(child.process.terminationStatus == 0, "\(child.errorText())")
        let canonicalPaths = try AgentLeasePaths.open(selectedRoot: fixture.stateRoot.path)
        let fields = child.outputText().split(separator: "|", omittingEmptySubsequences: false)
        #expect(fields.count == 5)
        #expect(fields[0] == Substring(canonicalPaths.rootPath))
        #expect(fields[1] != "stale")
        #expect(fields[2] == "a,b")
        #expect(fields[3] == "unset")
        #expect(fields[4] == "kept")
    }

    @Test("Nested invocation fails before creating state or starting a command")
    func nestedInvocation() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let marker = fixture.parent.appendingPathComponent("child-started")
        let child = try fixture.agentLease(
            ["run", "--resource", "nested", "--", "/usr/bin/touch", marker.path],
            environment: ["AGENTLEASE_HELD_RESOURCES": "   "]
        )
        child.process.waitUntilExit()

        #expect(child.process.terminationStatus == 70)
        #expect(!FileManager.default.fileExists(atPath: fixture.stateRoot.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Preflight maps missing and non-runnable commands without touching locks")
    func preflightFailures() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let missing = try fixture.agentLease([
            "run", "--resource", "preflight", "--", "/missing/agentlease-command",
        ])
        missing.process.waitUntilExit()
        #expect(missing.process.terminationStatus == 127)
        #expect(!FileManager.default.fileExists(atPath: fixture.stateRoot.path))

        let directory = try fixture.agentLease([
            "run", "--resource", "preflight", "--", "/tmp",
        ])
        directory.process.waitUntilExit()
        #expect(directory.process.terminationStatus == 126)
        #expect(!FileManager.default.fileExists(atPath: fixture.stateRoot.path))
    }

    @Test("PATH lookup skips empty and relative entries")
    func pathPolicy() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let executable = fixture.parent.appendingPathComponent("relative-only-tool")
        _ = FileManager.default.createFile(
            atPath: executable.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        let child = try fixture.agentLease(
            ["run", "--resource", "path", "--", executable.lastPathComponent],
            environment: ["PATH": ":."]
        )
        child.process.waitUntilExit()

        #expect(child.process.terminationStatus == 127)
        #expect(!FileManager.default.fileExists(atPath: fixture.stateRoot.path))
    }

    @Test("Launch-time ENOEXEC returns 126 without invoking a shell")
    func noImplicitShell() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let executable = fixture.parent.appendingPathComponent("plain-text")
        let sideEffect = fixture.parent.appendingPathComponent("side-effect")
        _ = FileManager.default.createFile(
            atPath: executable.path,
            contents: Data("touch \(sideEffect.path)\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        let child = try fixture.agentLease([
            "run", "--resource", "format", "--", executable.path,
        ])
        child.process.waitUntilExit()

        #expect(child.process.terminationStatus == 126, "\(child.errorText())")
        #expect(!FileManager.default.fileExists(atPath: sideEffect.path))
        let record = try #require(fixture.readRecords().first)
        #expect(record.state == .failed)
        #expect(record.failure?.kind == .executableNotRunnable)
    }

    @Test("The caller-selected argv zero reaches a PATH-resolved child unchanged")
    func exactArgumentZero() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let bin = fixture.parent.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        let helper = try builtExecutable(named: "agentlease-spike-helper")
        let commandName = "agentlease-argv-tool"
        try FileManager.default.createSymbolicLink(
            atPath: bin.appendingPathComponent(commandName).path,
            withDestinationPath: helper
        )
        let marker = fixture.parent.appendingPathComponent("arguments.json")
        let child = try fixture.agentLease(
            [
                "run", "--resource", "argv", "--", commandName,
                "write-arguments", marker.path,
            ],
            environment: ["PATH": "\(bin.path):/usr/bin:/bin"]
        )
        child.process.waitUntilExit()

        #expect(child.process.terminationStatus == 0, "\(child.errorText())")
        let arguments = try JSONDecoder().decode(
            [String].self,
            from: Data(contentsOf: marker)
        )
        #expect(arguments == [commandName, "write-arguments", marker.path])
        let record = try #require(fixture.readRecords().first)
        #expect(record.executable == commandName)
        #expect(record.resolvedExecutable == bin.appendingPathComponent(commandName).path)
    }

    @Test("A child signal is distinct from a signal received by the coordinator")
    func childSignalOutcome() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let helper = try builtExecutable(named: "agentlease-spike-helper")
        let child = try fixture.agentLease([
            "run", "--resource", "child-signal", "--", helper, "raise-interrupt",
        ])
        child.process.waitUntilExit()

        #expect(child.process.terminationStatus == 130, "\(child.errorText())")
        let record = try #require(fixture.readRecords().first)
        #expect(record.state == .signalled)
        #expect(record.receivedSignal == nil)
        #expect(record.termination == RunTermination(kind: .signal, value: SIGINT))

        let probe = try fixture.helper([
            "probe-lease", fixture.stateRoot.path, "child-signal",
        ])
        probe.process.waitUntilExit()
        #expect(probe.process.terminationStatus == 0, "\(probe.errorText())")
    }

    @Test("Stale running records do not prevent kernel-backed acquisition")
    func staleRecordDoesNotBlock() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let paths = try AgentLeasePaths.open(selectedRoot: fixture.stateRoot.path)
        let staleRecord = RunRecord(
            runID: "stale-run",
            mode: .run,
            state: .running,
            resources: ["stale"],
            label: "historical",
            bead: nil,
            coordinatorPID: 999_999,
            childPID: 999_998,
            workingDirectory: "/tmp",
            executable: "/usr/bin/false",
            resolvedExecutable: "/usr/bin/false",
            argumentCommitment: ArgumentCommitment.digest(arguments: ["/usr/bin/false"]),
            arguments: nil,
            startedAt: RunRecord.timestamp(),
            finishedAt: nil,
            receivedSignal: nil,
            termination: nil,
            failure: nil
        )
        try AtomicJSONStore(paths: paths).replace(staleRecord, named: "stale-run.json")

        let child = try fixture.agentLease([
            "run", "--resource", "stale", "--", "/usr/bin/true",
        ])
        child.process.waitUntilExit()

        #expect(child.process.terminationStatus == 0, "\(child.errorText())")
        let current = try #require(
            fixture.readRecords().first(where: {
                $0.coordinatorPID == child.process.processIdentifier
            })
        )
        #expect(current.state == .exited)
    }

    @Test("Raw invalid UTF-8 and control-bearing text fail before state creation")
    func invalidInputBeforeState() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let executable = try builtExecutable(named: "agentlease")
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTLEASE_HOME"] = fixture.stateRoot.path
        let rawResult = try runRawProcess(
            executablePath: executable,
            argumentBytes: [
                [0xff],
                Array("run".utf8),
                Array("--resource".utf8),
                Array("raw".utf8),
                Array("--".utf8),
                Array("/usr/bin/true".utf8),
            ],
            environment: environment
        )
        #expect(rawResult == 64)
        #expect(!FileManager.default.fileExists(atPath: fixture.stateRoot.path))

        let textResult = try fixture.agentLease([
            "run", "--resource", "text", "--label", "bad\nlabel",
            "--", "/usr/bin/true",
        ])
        textResult.process.waitUntilExit()
        #expect(textResult.process.terminationStatus == 64)
        #expect(!FileManager.default.fileExists(atPath: fixture.stateRoot.path))

        let delimiterResult = try fixture.agentLease([
            "run", "--resource", "delimiter", "/usr/bin/true",
        ])
        delimiterResult.process.waitUntilExit()
        #expect(delimiterResult.process.terminationStatus == 64)
        #expect(!FileManager.default.fileExists(atPath: fixture.stateRoot.path))
    }

    @Test("Zero-wait contention records timeout and releases a partial set")
    func timeoutCleanup() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let ready = fixture.parent.appendingPathComponent("owner-ready")
        let release = fixture.parent.appendingPathComponent("owner-release")
        let owner = try fixture.helper([
            "hold-lease", fixture.stateRoot.path, ready.path, release.path, "b",
        ])
        defer { terminate(owner.process) }
        while !FileManager.default.fileExists(atPath: ready.path), owner.process.isRunning {
            usleep(10_000)
        }

        let contender = try fixture.agentLease([
            "run", "--resource", "b", "--resource", "a", "--wait-seconds", "0",
            "--", "/usr/bin/true",
        ])
        contender.process.waitUntilExit()
        #expect(contender.process.terminationStatus == 75, "\(contender.errorText())")
        let record = try #require(
            fixture.readRecords().first(where: { $0.coordinatorPID == contender.process.processIdentifier })
        )
        #expect(record.state == .failed)
        #expect(record.failure?.kind == .acquisitionTimeout)

        let probe = try fixture.helper(["probe-lease", fixture.stateRoot.path, "a"])
        probe.process.waitUntilExit()
        #expect(probe.process.terminationStatus == 0, "\(probe.errorText())")
        try createMarker(release)
        owner.process.waitUntilExit()
    }

    @Test("A signal during acquisition releases partial ownership and never starts the child")
    func signalDuringAcquisition() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let ready = fixture.parent.appendingPathComponent("owner-ready")
        let release = fixture.parent.appendingPathComponent("owner-release")
        let childMarker = fixture.parent.appendingPathComponent("child-started")
        let owner = try fixture.helper([
            "hold-lease", fixture.stateRoot.path, ready.path, release.path, "b",
        ])
        defer { terminate(owner.process) }
        try await waitForMarker(ready, process: owner)

        let contender = try fixture.agentLease([
            "run", "--resource", "b", "--resource", "a", "--wait-seconds", "20",
            "--", "/usr/bin/touch", childMarker.path,
        ])
        let aLock = try fixture.lockPath(resource: "a")
        _ = try await waitForMetadata(
            at: aLock,
            coordinatorPID: contender.process.processIdentifier
        )
        #expect(kill(contender.process.processIdentifier, SIGINT) == 0)
        try await waitForProcessExit(contender.process)

        #expect(contender.process.terminationStatus == 130, "\(contender.errorText())")
        #expect(!FileManager.default.fileExists(atPath: childMarker.path))
        let record = try #require(
            fixture.readRecords().first(where: { $0.coordinatorPID == contender.process.processIdentifier })
        )
        #expect(record.state == .signalled)
        #expect(record.receivedSignal == SIGINT)
        #expect(record.termination == nil)
        let probe = try fixture.helper(["probe-lease", fixture.stateRoot.path, "a"])
        try await waitForProcessExit(probe.process)
        #expect(probe.process.terminationStatus == 0, "\(probe.errorText())")
        try createMarker(release)
        try await waitForProcessExit(owner.process)
    }

    @Test("Signal teardown kills the supervised process group and records the initiating signal")
    func signalTeardown() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let grandchildMarker = fixture.parent.appendingPathComponent("grandchild.pid")
        let helper = try builtExecutable(named: "agentlease-spike-helper")
        let coordinator = try fixture.agentLease([
            "run", "--resource", "signals", "--", helper,
            "spawn-ignoring-grandchild", grandchildMarker.path,
        ])
        defer { terminate(coordinator.process) }
        try await waitForMarker(grandchildMarker, process: coordinator)
        let runningRecord = try #require(
            fixture.readRecords().first(where: { $0.coordinatorPID == coordinator.process.processIdentifier })
        )
        let childPID = try #require(runningRecord.childPID)
        defer { _ = kill(-childPID, SIGKILL) }

        #expect(kill(coordinator.process.processIdentifier, SIGTERM) == 0)
        try await waitForProcessExit(coordinator.process, timeout: .seconds(10))
        #expect(coordinator.process.terminationStatus == 143)
        try await waitForProcessGroupExit(childPID)

        let record = try #require(
            fixture.readRecords().first(where: { $0.coordinatorPID == coordinator.process.processIdentifier })
        )
        #expect(record.state == .signalled)
        #expect(record.receivedSignal == SIGTERM)
        #expect(record.termination == nil)
    }

    @Test("A running-record failure tears down and reaps before releasing ownership")
    func runningPublicationFailure() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let blockedError = Pipe()
        try fillPipe(blockedError)
        let helper = try builtExecutable(named: "agentlease-spike-helper")
        let childMarker = fixture.parent.appendingPathComponent("record-failure-child.pid")
        let coordinator = try fixture.agentLease(
            [
                "run", "--resource", "record-failure", "--", helper,
                "hold-inherited-locks", childMarker.path,
            ],
            standardError: blockedError
        )
        defer { terminate(coordinator.process) }

        let acquired = try await fixture.waitForRecord(
            coordinatorPID: coordinator.process.processIdentifier,
            state: .acquired
        )
        let recordURL = fixture.stateRoot
            .appendingPathComponent("runs")
            .appendingPathComponent("\(acquired.runID).json")
        let preservedRecord = recordURL.appendingPathExtension("preserved")
        try FileManager.default.moveItem(at: recordURL, to: preservedRecord)
        try FileManager.default.createDirectory(
            at: recordURL,
            withIntermediateDirectories: false
        )
        try drainAvailablePipeData(blockedError)
        try blockedError.fileHandleForWriting.close()

        try await waitForProcessExit(coordinator.process, timeout: .seconds(10))
        #expect(coordinator.process.terminationStatus == 70)
        let diagnostics = coordinator.errorText()
        #expect(diagnostics.contains("recordPublication:"))
        #expect(diagnostics.contains("could not publish failure record:"))

        let metadata = try JSONDecoder().decode(
            LockMetadata.self,
            from: Data(contentsOf: fixture.lockPath(resource: "record-failure"))
        )
        #expect(metadata.state == .failed)
        let childPID = try #require(metadata.childPID)
        errno = 0
        #expect(kill(childPID, 0) == -1)
        #expect(errno == ESRCH)

        let probe = try fixture.helper([
            "probe-lease", fixture.stateRoot.path, "record-failure",
        ])
        try await waitForProcessExit(probe.process)
        #expect(probe.process.terminationStatus == 0, "\(probe.errorText())")
    }

    @Test("Terminal publication failures preserve nonzero outcomes and override success")
    func terminalPublicationPrecedence() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let helper = try builtExecutable(named: "agentlease-spike-helper")

        for (childExit, expectedExit) in [(0, 70), (23, 23)] {
            let resource = "terminal-publication-\(childExit)"
            let release = fixture.parent.appendingPathComponent("release-\(childExit)")
            let coordinator = try fixture.agentLease([
                "run", "--resource", resource, "--", helper,
                "wait-for-marker-and-exit", release.path, String(childExit),
            ])
            defer { terminate(coordinator.process) }

            let running = try await fixture.waitForRecord(
                coordinatorPID: coordinator.process.processIdentifier,
                state: .running,
                process: coordinator
            )
            let recordURL = fixture.stateRoot
                .appendingPathComponent("runs")
                .appendingPathComponent("\(running.runID).json")
            try FileManager.default.moveItem(
                at: recordURL,
                to: recordURL.appendingPathExtension("preserved")
            )
            try FileManager.default.createDirectory(
                at: recordURL,
                withIntermediateDirectories: false
            )
            try createMarker(release)

            try await waitForProcessExit(coordinator.process)
            #expect(coordinator.process.terminationStatus == expectedExit)
            #expect(coordinator.errorText().contains("could not publish terminal record:"))
            let metadata = try JSONDecoder().decode(
                LockMetadata.self,
                from: Data(contentsOf: fixture.lockPath(resource: resource))
            )
            #expect(metadata.state == .exited)
            #expect(metadata.childPID == running.childPID)

            let probe = try fixture.helper([
                "probe-lease", fixture.stateRoot.path, resource,
            ])
            try await waitForProcessExit(probe.process)
            #expect(probe.process.terminationStatus == 0, "\(probe.errorText())")
            try FileManager.default.removeItem(at: recordURL)
        }
    }

    @Test("A supervised child retains ownership after coordinator SIGKILL")
    func supervisorDeathRetention() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let childMarker = fixture.parent.appendingPathComponent("child.pid")
        let helper = try builtExecutable(named: "agentlease-spike-helper")
        let coordinator = try fixture.agentLease([
            "run", "--resource", "crash", "--", helper,
            "hold-inherited-locks", childMarker.path,
        ])
        defer { terminate(coordinator.process) }
        try await waitForMarker(childMarker, process: coordinator)
        let childPID = try readProcessIdentifier(from: childMarker)
        defer { _ = kill(childPID, SIGKILL) }

        #expect(kill(coordinator.process.processIdentifier, SIGKILL) == 0)
        try await waitForProcessExit(coordinator.process)
        let blocked = try fixture.helper(["probe-lease", fixture.stateRoot.path, "crash"])
        try await waitForProcessExit(blocked.process)
        #expect(blocked.process.terminationStatus == 75, "\(blocked.errorText())")

        #expect(kill(childPID, SIGKILL) == 0)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var acquired = false
        while clock.now < deadline, !acquired {
            let probe = try fixture.helper(["probe-lease", fixture.stateRoot.path, "crash"])
            try await waitForProcessExit(probe.process)
            acquired = probe.process.terminationStatus == 0
            if !acquired {
                try await clock.sleep(for: .milliseconds(20))
            }
        }
        #expect(acquired)
    }
}
