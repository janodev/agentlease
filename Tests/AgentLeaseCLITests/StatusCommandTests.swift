import AgentLeaseCore
import Foundation
import Testing

@Suite("agentlease status", .serialized)
struct StatusCommandTests {
    @Test("JSON reports held then historical free state and remains usable when nested")
    func heldFreeAndNested() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let helper = try builtExecutable(named: "agentlease-spike-helper")
        let release = fixture.parent.appendingPathComponent("status-release")
        let owner = try fixture.agentLease([
            "run", "--resource", "status-cli", "--", helper,
            "wait-for-marker-and-exit", release.path, "0",
        ])
        defer { terminate(owner.process) }
        let running = try await fixture.waitForRecord(
            coordinatorPID: owner.process.processIdentifier,
            state: .running,
            process: owner
        )

        let heldStatus = try fixture.agentLease(
            ["status", "--json"],
            environment: ["AGENTLEASE_HELD_RESOURCES": "outer:lease"]
        )
        try await waitForProcessExit(heldStatus.process)
        #expect(heldStatus.process.terminationStatus == 0, "\(heldStatus.errorText())")
        let heldReport = try JSONDecoder().decode(
            StatusReport.self,
            from: heldStatus.standardOutput.fileHandleForReading.readDataToEndOfFile()
        )
        let held = try #require(heldReport.entries.first)
        #expect(held.availability == .held)
        #expect(held.metadataStatus == .valid)
        #expect(held.resource == "status-cli")
        #expect(held.lastOwner?.runID == running.runID)

        try createMarker(release)
        try await waitForProcessExit(owner.process)
        let freeStatus = try fixture.agentLease(["status", "--json"])
        try await waitForProcessExit(freeStatus.process)
        #expect(freeStatus.process.terminationStatus == 0, "\(freeStatus.errorText())")
        let freeReport = try JSONDecoder().decode(
            StatusReport.self,
            from: freeStatus.standardOutput.fileHandleForReading.readDataToEndOfFile()
        )
        let free = try #require(freeReport.entries.first)
        #expect(free.availability == .free)
        #expect(free.metadataStatus == .valid)
        #expect(free.lastOwner?.state == .exited)

        let humanStatus = try fixture.agentLease(["status"])
        try await waitForProcessExit(humanStatus.process)
        #expect(humanStatus.process.terminationStatus == 0)
        #expect(humanStatus.outputText().contains("historical-run=\(running.runID)"))
    }

    @Test("Unexpected entries are all reported in filename order and return 70")
    func unexpectedEntries() async throws {
        let fixture = try CLIFixture()
        defer { fixture.remove() }
        let paths = try AgentLeasePaths.open(selectedRoot: fixture.stateRoot.path)
        let validResource = try ResourceName("status-valid")
        try FileLock(resource: validResource, paths: paths).release()
        let unexpected = URL(fileURLWithPath: paths.rootPath)
            .appendingPathComponent("locks")
            .appendingPathComponent("unexpected-entry")
        _ = FileManager.default.createFile(atPath: unexpected.path, contents: Data())

        let status = try fixture.agentLease(["status", "--json"])
        try await waitForProcessExit(status.process)
        #expect(status.process.terminationStatus == 70)
        let report = try JSONDecoder().decode(
            StatusReport.self,
            from: status.standardOutput.fileHandleForReading.readDataToEndOfFile()
        )
        #expect(report.entries.count == 2)
        #expect(
            report.entries.map(\.fileName)
                == report.entries.map(\.fileName).sorted(by: utf8StatusPrecedes)
        )
        let unknown = try #require(
            report.entries.first(where: { $0.fileName == "unexpected-entry" })
        )
        #expect(unknown.digest == nil)
        #expect(unknown.resource == nil)
        #expect(unknown.availability == .unknown)
        #expect(unknown.error != nil)
        #expect(FileManager.default.fileExists(atPath: unexpected.path))
    }
}

private func utf8StatusPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
