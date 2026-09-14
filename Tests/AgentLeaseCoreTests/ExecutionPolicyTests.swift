@testable import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("Shared execution policy")
struct ExecutionPolicyTests {
    @Test("Argument commitments are domain-separated and length-prefixed")
    func argumentCommitment() {
        #expect(
            ArgumentCommitment.digest(arguments: ["ab", "c"])
                != ArgumentCommitment.digest(arguments: ["a", "bc"])
        )
        #expect(
            ArgumentCommitment.digest(arguments: ["tool", "one", "two"])
                == "ff916e902f4adf6a085e1a6ccb17dd307171eba68c360b08f26a5ea9a8d633a8"
        )
    }

    @Test("Text metadata permits format scalars and rejects control scalars")
    func textValidation() throws {
        try TextFieldValidator.validate("family: 👩‍👩‍👧‍👦", field: "label")
        #expect(throws: TextFieldValidationError.self) {
            try TextFieldValidator.validate("line\nfeed", field: "label")
        }
        #expect(throws: TextFieldValidationError.self) {
            try TextFieldValidator.validate("control\u{0085}", field: "bead")
        }
        #expect(throws: TextFieldValidationError.self) {
            try TextFieldValidator.validate("", field: "label")
        }
    }

    @Test("Child environment overwrites reservations, removes stale bead, and preserves others")
    func childEnvironment() throws {
        let resources = try ResourceSet(["b", "a"])
        let inherited = [
            "AGENTLEASE_BEAD_ID": "stale",
            "AGENTLEASE_HELD_RESOURCES": "stale",
            "AGENTLEASE_HOME": "/stale",
            "AGENTLEASE_RUN_ID": "stale",
            "AGENTLEASE_LEASE_DESCRIPTORS": "stale",
            "UNRELATED": "kept",
        ]
        let environment = ChildEnvironment.build(
            inherited: inherited,
            stateRoot: "/actual",
            runID: "new-run",
            resources: resources,
            bead: nil
        )

        #expect(environment["AGENTLEASE_HOME"] == "/actual")
        #expect(environment["AGENTLEASE_RUN_ID"] == "new-run")
        #expect(environment["AGENTLEASE_HELD_RESOURCES"] == "a,b")
        #expect(environment["AGENTLEASE_BEAD_ID"] == nil)
        #expect(environment["AGENTLEASE_LEASE_DESCRIPTORS"] == nil)
        #expect(environment["UNRELATED"] == "kept")
    }

    @Test("Inherited lease manifest is deterministic, bounded, and validated")
    func inheritedLeaseManifest() throws {
        let leases = [
            InheritedLeaseDescriptor(
                resource: "a:shared",
                mode: .shared,
                descriptor: 64,
                path: "/tmp/state/locks/\(try ResourceName("a:shared").lockFileName)"
            ),
            InheritedLeaseDescriptor(
                resource: "z:exclusive",
                mode: .exclusive,
                descriptor: 65,
                path: "/tmp/state/locks/\(try ResourceName("z:exclusive").lockFileName)"
            ),
        ]
        let value = try InheritedLeaseManifest(leases: leases).environmentValue()
        let repeatedValue = try InheritedLeaseManifest(leases: leases).environmentValue()
        #expect(value == repeatedValue)
        let expected = "{\"leases\":[{\"descriptor\":64,\"mode\":\"shared\","
            + "\"path\":\"\(leases[0].path)\",\"resource\":\"a:shared\"},"
            + "{\"descriptor\":65,\"mode\":\"exclusive\","
            + "\"path\":\"\(leases[1].path)\",\"resource\":\"z:exclusive\"}],"
            + "\"schemaVersion\":1}"
        #expect(value == expected)
        #expect(value.utf8.count <= InheritedLeaseManifest.maximumEncodedBytes)
        #expect(try InheritedLeaseManifest.decodeEnvironmentValue(value).leases == leases)

        let unsorted = [leases[1], leases[0]]
        #expect(throws: InheritedLeaseManifestError.unsortedResources) {
            _ = try InheritedLeaseManifest(leases: unsorted).environmentValue()
        }
        let controlledPath = InheritedLeaseDescriptor(
            resource: "a:shared",
            mode: .shared,
            descriptor: 64,
            path: "/tmp/control\n/locks/\(try ResourceName("a:shared").lockFileName)"
        )
        #expect(throws: InheritedLeaseManifestError.self) {
            _ = try InheritedLeaseManifest(leases: [controlledPath]).environmentValue()
        }

        let oversized = try (0..<ResourceSet.maximumCount).map { index in
            let resource = try ResourceName(String(format: "r%02d", index))
            return InheritedLeaseDescriptor(
                resource: resource.value,
                mode: .shared,
                descriptor: Int32(FileLock.minimumOwnedDescriptor) + Int32(index),
                path: "/" + String(repeating: "x", count: 3_000)
                    + "/locks/" + resource.lockFileName
            )
        }
        #expect(throws: InheritedLeaseManifestError.self) {
            _ = try InheritedLeaseManifest(leases: oversized).environmentValue()
        }
    }

    @Test("Version one lock metadata decodes as exclusive")
    func legacyLockMetadata() throws {
        let value = """
        {"schemaVersion":1,"resourceName":"legacy","runID":"run","coordinatorPID":1,"childPID":null,"mode":"run","state":"running","label":null,"bead":null,"acquiredAt":"time"}
        """
        let metadata = try JSONDecoder().decode(LockMetadata.self, from: Data(value.utf8))
        #expect(metadata.schemaVersion == 1)
        #expect(metadata.leaseMode == .exclusive)
    }

    @Test("Executable paths are lexical and executable symlinks are allowed")
    func explicitPathResolution() async throws {
        let directory = try makeAgentLeaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("real")
        let linked = directory.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        let executable = real.appendingPathComponent("tool")
        _ = FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let resolved = try await ExecutableResolver.resolve(
            "./tool",
            workingDirectory: linked.path,
            environment: [:]
        )
        #expect(resolved.path == linked.appendingPathComponent("tool").path)
    }

    @Test("Name resolution skips relative and empty PATH entries")
    func pathSearchPolicy() async throws {
        let directory = try makeAgentLeaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let absoluteBin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(
            at: absoluteBin,
            withIntermediateDirectories: false
        )
        let name = "agentlease-policy-tool"
        let executable = absoluteBin.appendingPathComponent(name)
        _ = FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let resolved = try await ExecutableResolver.resolve(
            name,
            workingDirectory: directory.path,
            environment: ["PATH": ":relative:\(absoluteBin.path)"]
        )
        #expect(resolved.path == executable.path)

        await #expect(throws: ExecutableResolutionError.self) {
            _ = try await ExecutableResolver.resolve(
                name,
                workingDirectory: absoluteBin.path,
                environment: ["PATH": ":relative"]
            )
        }
    }

    @Test("Explicit missing, directory, and non-executable paths map before acquisition")
    func executablePreflight() async throws {
        let directory = try makeAgentLeaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plainFile = directory.appendingPathComponent("plain")
        _ = FileManager.default.createFile(atPath: plainFile.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plainFile.path)

        await #expect(throws: ExecutableResolutionError.self) {
            _ = try await ExecutableResolver.resolve(
                directory.appendingPathComponent("missing").path,
                workingDirectory: directory.path,
                environment: [:]
            )
        }
        await #expect(throws: ExecutableResolutionError.self) {
            _ = try await ExecutableResolver.resolve(
                directory.path,
                workingDirectory: directory.path,
                environment: [:]
            )
        }
        await #expect(throws: ExecutableResolutionError.self) {
            _ = try await ExecutableResolver.resolve(
                plainFile.path,
                workingDirectory: directory.path,
                environment: [:]
            )
        }
    }
}
