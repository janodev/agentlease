@testable import AgentLeaseCore
import Foundation
import Testing

@Suite("Atomic JSON records", .serialized)
struct AtomicJSONStoreTests {
    @Test("Atomically creates and replaces exact-mode JSON")
    func createAndReplace() throws {
        let fixture = try RecordFixture()
        defer { fixture.remove() }
        let store = AtomicJSONStore(paths: fixture.paths)

        try store.replace(["value": 1], named: "record.json")
        #expect(try fixture.decodeValue() == 1)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.record.path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try store.replace(["value": 2], named: "record.json")
        #expect(try fixture.decodeValue() == 2)
        #expect(try fixture.temporaryEntries().isEmpty)
    }

    @Test("Injected write, file-sync, and rename failures preserve the prior record")
    func preReplacementFailures() throws {
        for point in [
            AtomicJSONStore.FailurePoint.write,
            .fileSync,
            .rename,
        ] {
            let fixture = try RecordFixture()
            defer { fixture.remove() }
            try AtomicJSONStore(paths: fixture.paths).replace(
                ["value": 1],
                named: "record.json"
            )

            let failingStore = AtomicJSONStore(paths: fixture.paths, failurePoint: point)
            #expect(throws: AtomicJSONStoreError.self) {
                try failingStore.replace(["value": 2], named: "record.json")
            }
            #expect(try fixture.decodeValue() == 1)
            #expect(try fixture.temporaryEntries().isEmpty)
        }
    }

    @Test("An injected directory-sync failure reports after atomic replacement")
    func directorySyncFailure() throws {
        let fixture = try RecordFixture()
        defer { fixture.remove() }
        try AtomicJSONStore(paths: fixture.paths).replace(
            ["value": 1],
            named: "record.json"
        )

        let failingStore = AtomicJSONStore(
            paths: fixture.paths,
            failurePoint: .directorySync
        )
        #expect(throws: AtomicJSONStoreError.self) {
            try failingStore.replace(["value": 2], named: "record.json")
        }
        #expect(try fixture.decodeValue() == 2)
        #expect(try fixture.temporaryEntries().isEmpty)
    }

    @Test("Run records retain nullable keys and structured failure keys")
    func stableNullableShape() throws {
        let fixture = try RecordFixture()
        defer { fixture.remove() }
        let record = RunRecord(
            runID: "test-run",
            mode: .run,
            state: .acquiring,
            resources: ["example:build"],
            label: nil,
            bead: nil,
            coordinatorPID: 1,
            childPID: nil,
            workingDirectory: "/tmp",
            executable: "make",
            resolvedExecutable: "/usr/bin/make",
            argumentCommitment: "digest",
            arguments: nil,
            startedAt: "2026-09-13T00:00:00Z",
            finishedAt: nil,
            receivedSignal: nil,
            termination: nil,
            failure: AgentLeaseFailure(
                kind: .acquisitionTimeout,
                operation: "flock",
                resource: "example:build",
                message: "timed out waiting for the resource"
            )
        )
        try AtomicJSONStore(paths: fixture.paths).replace(record, named: "record.json")

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.record))
                as? [String: Any]
        )
        for key in [
            "arguments", "bead", "childPID", "finishedAt", "label", "receivedSignal",
            "termination",
        ] {
            #expect(object[key] is NSNull)
        }
        let failure = try #require(object["failure"] as? [String: Any])
        #expect(failure["errno"] is NSNull)
        #expect(failure["resource"] as? String == "example:build")
        #expect(Set(failure.keys) == Set(["kind", "operation", "errno", "resource", "message"]))
    }
}

private struct RecordFixture {
    let paths: AgentLeasePaths
    let record: URL
    let root: URL

    init() throws {
        let parent = try makeAgentLeaseTemporaryDirectory()
        root = parent.appendingPathComponent("state")
        record = root.appendingPathComponent("runs/record.json")
        paths = try AgentLeasePaths.open(selectedRoot: root.path)
    }

    func decodeValue() throws -> Int {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: record))
        let dictionary = try #require(object as? [String: Int])
        return try #require(dictionary["value"])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func temporaryEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("runs").path
        ).filter { $0.hasPrefix(".") }
    }
}
