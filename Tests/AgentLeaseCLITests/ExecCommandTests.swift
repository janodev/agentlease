import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("agentlease exec", .serialized)
struct ExecCommandTests {
    @Test("Replacement preserves streams, environment, child status, and handoff record")
    func streamsEnvironmentAndRecord() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let input = Pipe()
        let script = "IFS= read -r line; printf '%s|%s|%s|%s|%s' \"$line\" \"$AGENTLEASE_HELD_RESOURCES\" \"$AGENTLEASE_HOME\" \"${AGENTLEASE_BEAD_ID-unset}\" \"$UNRELATED\"; printf 'exec-err' >&2; exit 23"
        let process = try fixture.agentLease(
            ["exec", "--resource", "stdio", "--", "/bin/sh", "-c", script],
            environment: [
                "AGENTLEASE_BEAD_ID": "stale",
                "UNRELATED": "kept",
            ],
            standardInput: input
        )
        try input.fileHandleForWriting.write(contentsOf: Data("interactive-input\n".utf8))
        try input.fileHandleForWriting.close()
        process.process.waitUntilExit()

        #expect(process.process.terminationStatus == 23)
        #expect(process.errorText().contains("exec-err"))
        let canonicalPaths = try AgentLeasePaths.open(selectedRoot: fixture.stateRoot.path)
        let fields = process.outputText().split(separator: "|", omittingEmptySubsequences: false)
        #expect(fields == [
            "interactive-input",
            "stdio",
            Substring(canonicalPaths.rootPath),
            "unset",
            "kept",
        ])

        let record = try #require(fixture.readRecords().first)
        #expect(record.mode == .exec)
        #expect(record.state == .handoffPrepared)
        #expect(record.coordinatorPID == process.process.processIdentifier)
        #expect(record.childPID == nil)
        #expect(record.finishedAt == nil)
        #expect(record.termination == nil)
        #expect(record.arguments == nil)

        let probe = try fixture.helper([
            "probe-lease", fixture.stateRoot.path, "stdio",
        ])
        probe.process.waitUntilExit()
        #expect(probe.process.terminationStatus == 0, "\(probe.errorText())")
    }

    @Test("PATH replacement preserves exact argv zero and recorded arguments")
    func exactArguments() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let bin = fixture.parent.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        let helper = try builtExecutable(named: "agentlease-spike-helper")
        let commandName = "agentlease-exec-argv"
        try FileManager.default.createSymbolicLink(
            atPath: bin.appendingPathComponent(commandName).path,
            withDestinationPath: helper
        )
        let marker = fixture.parent.appendingPathComponent("exec-arguments.json")
        let process = try fixture.agentLease(
            [
                "exec", "--resource", "exec-argv", "--record-arguments", "--",
                commandName, "write-arguments", marker.path,
            ],
            environment: ["PATH": "relative::\(bin.path):/usr/bin:/bin"]
        )
        process.process.waitUntilExit()

        #expect(process.process.terminationStatus == 0, "\(process.errorText())")
        let arguments = try JSONDecoder().decode(
            [String].self,
            from: Data(contentsOf: marker)
        )
        let expectedArguments = [commandName, "write-arguments", marker.path]
        #expect(arguments == expectedArguments)
        let record = try #require(fixture.readRecords().first)
        #expect(record.executable == commandName)
        #expect(record.arguments == expectedArguments)
        #expect(record.argumentCommitment == ArgumentCommitment.digest(arguments: expectedArguments))
    }

    @Test("Normal signal and SIGKILL death release directly inherited ownership")
    func signalAndCrashRelease() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let helper = try builtExecutable(named: "agentlease-spike-helper")

        for (signalNumber, suffix) in [(SIGTERM, "signal"), (SIGKILL, "crash")] {
            let marker = fixture.parent.appendingPathComponent("exec-\(suffix).pid")
            let resources = ["exec-\(suffix)-a", "exec-\(suffix)-b"]
            let process = try fixture.agentLease([
                "exec", "--resource", resources[1], "--resource", resources[0],
                "--", helper, "hold-inherited-locks", marker.path, "2",
            ])
            defer { terminate(process.process) }
            try await waitForMarker(marker, process: process)

            let heldProbe = try fixture.helper([
                "probe-lease", fixture.stateRoot.path, resources[0], resources[1],
            ])
            try await waitForProcessExit(heldProbe.process)
            #expect(heldProbe.process.terminationStatus == 75, "\(heldProbe.errorText())")

            #expect(kill(process.process.processIdentifier, signalNumber) == 0)
            try await waitForProcessExit(process.process)
            #expect(process.process.terminationReason == .uncaughtSignal)
            #expect(process.process.terminationStatus == signalNumber)
            let record = try #require(
                fixture.readRecords().first(where: {
                    $0.coordinatorPID == process.process.processIdentifier
                })
            )
            #expect(record.state == .handoffPrepared)

            let freeProbe = try fixture.helper([
                "probe-lease", fixture.stateRoot.path, resources[0], resources[1],
            ])
            try await waitForProcessExit(freeProbe.process)
            #expect(freeProbe.process.terminationStatus == 0, "\(freeProbe.errorText())")
        }
    }

    @Test("An inheriting exec descendant retains the lease after its parent exits")
    func descendantRetention() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let helper = try builtExecutable(named: "agentlease-spike-helper")
        let marker = fixture.parent.appendingPathComponent("exec-descendant.pid")
        let process = try fixture.agentLease([
            "exec", "--resource", "exec-descendant", "--", helper,
            "spawn-inheriting-descendant-and-exit", marker.path,
        ])
        defer { terminate(process.process) }
        try await waitForProcessExit(process.process)
        #expect(process.process.terminationStatus == 0)
        try await waitForMarker(marker)
        let descendantPID = try readProcessIdentifier(from: marker)
        defer { _ = kill(descendantPID, SIGKILL) }

        let blocked = try fixture.helper([
            "probe-lease", fixture.stateRoot.path, "exec-descendant",
        ])
        try await waitForProcessExit(blocked.process)
        #expect(blocked.process.terminationStatus == 75, "\(blocked.errorText())")

        #expect(kill(descendantPID, SIGKILL) == 0)
        var acquired = false
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline, !acquired {
            let probe = try fixture.helper([
                "probe-lease", fixture.stateRoot.path, "exec-descendant",
            ])
            try await waitForProcessExit(probe.process)
            acquired = probe.process.terminationStatus == 0
            if !acquired {
                try await clock.sleep(for: .milliseconds(20))
            }
        }
        #expect(acquired)
    }

    @Test("A signal during direct acquisition uses ordinary termination and releases partial locks")
    func signalDuringAcquisition() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let ready = fixture.parent.appendingPathComponent("exec-owner-ready")
        let release = fixture.parent.appendingPathComponent("exec-owner-release")
        let childMarker = fixture.parent.appendingPathComponent("exec-child-started")
        let owner = try fixture.helper([
            "hold-lease", fixture.stateRoot.path, ready.path, release.path, "b",
        ])
        defer { terminate(owner.process) }
        try await waitForMarker(ready, process: owner)

        let process = try fixture.agentLease([
            "exec", "--resource", "b", "--resource", "a", "--wait-seconds", "20",
            "--", "/usr/bin/touch", childMarker.path,
        ])
        defer { terminate(process.process) }
        _ = try await waitForMetadata(
            at: fixture.lockPath(resource: "a"),
            coordinatorPID: process.process.processIdentifier
        )
        #expect(kill(process.process.processIdentifier, SIGINT) == 0)
        try await waitForProcessExit(process.process)

        #expect(process.process.terminationReason == .uncaughtSignal)
        #expect(process.process.terminationStatus == SIGINT)
        #expect(!FileManager.default.fileExists(atPath: childMarker.path))
        let record = try #require(
            fixture.readRecords().first(where: {
                $0.coordinatorPID == process.process.processIdentifier
            })
        )
        #expect(record.state == .acquiring)
        #expect(record.finishedAt == nil)

        let probe = try fixture.helper(["probe-lease", fixture.stateRoot.path, "a"])
        try await waitForProcessExit(probe.process)
        #expect(probe.process.terminationStatus == 0, "\(probe.errorText())")
        try createMarker(release)
        try await waitForProcessExit(owner.process)
    }

    @Test("Direct launch errors never invoke a shell and use shared 126 and 127 mapping")
    func launchErrors() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let plainText = fixture.parent.appendingPathComponent("plain-text")
        let sideEffect = fixture.parent.appendingPathComponent("side-effect")
        _ = FileManager.default.createFile(
            atPath: plainText.path,
            contents: Data("touch \(sideEffect.path)\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: plainText.path
        )
        let format = try fixture.agentLease([
            "exec", "--resource", "exec-format", "--", plainText.path,
        ])
        format.process.waitUntilExit()
        #expect(format.process.terminationStatus == 126, "\(format.errorText())")
        #expect(!FileManager.default.fileExists(atPath: sideEffect.path))

        let missingInterpreter = fixture.parent.appendingPathComponent("missing-interpreter")
        _ = FileManager.default.createFile(
            atPath: missingInterpreter.path,
            contents: Data("#!/missing/agentlease-interpreter\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: missingInterpreter.path
        )
        let interpreter = try fixture.agentLease([
            "exec", "--resource", "exec-interpreter", "--", missingInterpreter.path,
        ])
        interpreter.process.waitUntilExit()
        #expect(interpreter.process.terminationStatus == 127, "\(interpreter.errorText())")

        let records = try fixture.readRecords()
        let formatRecord = try #require(
            records.first(where: { $0.coordinatorPID == format.process.processIdentifier })
        )
        #expect(formatRecord.state == .failed)
        #expect(formatRecord.failure?.kind == .executableNotRunnable)
        let interpreterRecord = try #require(
            records.first(where: { $0.coordinatorPID == interpreter.process.processIdentifier })
        )
        #expect(interpreterRecord.state == .failed)
        #expect(interpreterRecord.failure?.kind == .executableNotFound)
    }

    @Test("Direct preflight failure occurs before state or lock creation")
    func preflightBeforeState() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let process = try fixture.agentLease([
            "exec", "--resource", "exec-preflight", "--",
            "/missing/agentlease-command",
        ])
        process.process.waitUntilExit()

        #expect(process.process.terminationStatus == 127)
        #expect(!FileManager.default.fileExists(atPath: fixture.stateRoot.path))
    }

    @Test("Direct PATH lookup skips an executable in empty and relative entries")
    func relativePathIsSkipped() throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let executable = fixture.parent.appendingPathComponent("relative-exec-tool")
        _ = FileManager.default.createFile(
            atPath: executable.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        let process = try fixture.agentLease(
            ["exec", "--resource", "exec-path", "--", executable.lastPathComponent],
            currentDirectory: fixture.parent,
            environment: ["PATH": ":."]
        )
        process.process.waitUntilExit()

        #expect(process.process.terminationStatus == 127)
        #expect(!FileManager.default.fileExists(atPath: fixture.stateRoot.path))
    }

    @Test("A handoff record failure prevents replacement and releases ownership")
    func handoffPublicationFailure() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let blockedError = Pipe()
        try fillPipe(blockedError)
        let childMarker = fixture.parent.appendingPathComponent("exec-should-not-start")
        let process = try fixture.agentLease(
            [
                "exec", "--resource", "exec-record-failure", "--",
                "/usr/bin/touch", childMarker.path,
            ],
            standardError: blockedError
        )
        defer { terminate(process.process) }

        let acquired = try await fixture.waitForRecord(
            coordinatorPID: process.process.processIdentifier,
            state: .acquired
        )
        let recordURL = fixture.stateRoot
            .appendingPathComponent("runs")
            .appendingPathComponent("\(acquired.runID).json")
        try FileManager.default.moveItem(
            at: recordURL,
            to: recordURL.appendingPathExtension("preserved")
        )
        try FileManager.default.createDirectory(
            at: recordURL,
            withIntermediateDirectories: false
        )
        try drainAvailablePipeData(blockedError)
        try blockedError.fileHandleForWriting.close()

        try await waitForProcessExit(process.process)
        #expect(process.process.terminationStatus == 70)
        #expect(!FileManager.default.fileExists(atPath: childMarker.path))
        let diagnostics = process.errorText()
        #expect(diagnostics.contains("recordPublication:"))
        #expect(diagnostics.contains("could not publish failure record:"))
        let metadata = try JSONDecoder().decode(
            LockMetadata.self,
            from: Data(contentsOf: fixture.lockPath(resource: "exec-record-failure"))
        )
        #expect(metadata.state == .failed)

        let probe = try fixture.helper([
            "probe-lease", fixture.stateRoot.path, "exec-record-failure",
        ])
        try await waitForProcessExit(probe.process)
        #expect(probe.process.terminationStatus == 0, "\(probe.errorText())")
    }
}
