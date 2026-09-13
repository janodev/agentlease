@testable import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("Safe state paths", .serialized)
struct AgentLeasePathsTests {
    @Test("Default root ignores HOME and explicit AgentLease home remains authoritative")
    func stateRootSelection() throws {
        let defaultRoot = try AgentLeasePaths.selectedRoot(
            environment: ["HOME": "/tmp/conflicting-home"]
        )
        #expect(defaultRoot.hasSuffix("/.agentlease"))
        #expect(!defaultRoot.hasPrefix("/tmp/conflicting-home/"))
        #expect(
            try AgentLeasePaths.selectedRoot(
                environment: ["AGENTLEASE_HOME": "/tmp/explicit-agentlease"]
            ) == "/tmp/explicit-agentlease"
        )
    }

    @Test("Creates only the final root and managed directories with exact modes")
    func createsExactLayoutUnderRestrictiveUmask() throws {
        let parent = try makeAgentLeaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("state")

        let helper = try launchAgentLeaseHelper(["prepare-state-restrictive", root.path])
        helper.process.waitUntilExit()
        #expect(
            helper.process.terminationStatus == 0,
            "state helper failed:\n\(helper.readOutput())"
        )

        for directory in [root, root.appendingPathComponent("locks"), root.appendingPathComponent("runs")] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
    }

    @Test("Canonicalizes the parent but leaves the final component unresolved")
    func canonicalParentAndRootSymlinkRejection() throws {
        let parent = try makeAgentLeaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let realParent = parent.appendingPathComponent("real")
        let linkedParent = parent.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)

        let paths = try AgentLeasePaths.open(
            selectedRoot: linkedParent.appendingPathComponent("state").path
        )
        #expect(paths.rootPath.hasSuffix("/real/state"))
        #expect(!paths.rootPath.contains("/linked/"))

        let target = parent.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        let symlinkRoot = parent.appendingPathComponent("symlink-root")
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: target)
        #expect(throws: AgentLeasePathError.self) {
            _ = try AgentLeasePaths.open(selectedRoot: symlinkRoot.path)
        }
    }

    @Test("Rejects empty, relative, missing-parent, and unsafe managed paths")
    func rejectsUnsafePaths() throws {
        #expect(throws: AgentLeasePathError.self) {
            _ = try AgentLeasePaths.open(environment: ["AGENTLEASE_HOME": ""])
        }
        #expect(throws: AgentLeasePathError.self) {
            _ = try AgentLeasePaths.open(selectedRoot: "relative/state")
        }

        let parent = try makeAgentLeaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        #expect(throws: AgentLeasePathError.self) {
            _ = try AgentLeasePaths.open(
                selectedRoot: parent.appendingPathComponent("missing/state").path
            )
        }

        let unsafeRoot = parent.appendingPathComponent("unsafe")
        try FileManager.default.createDirectory(at: unsafeRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: unsafeRoot.path
        )
        #expect(throws: AgentLeasePathError.self) {
            _ = try AgentLeasePaths.open(selectedRoot: unsafeRoot.path)
        }

        let managedRoot = parent.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: managedRoot.path
        )
        let target = parent.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let locks = managedRoot.appendingPathComponent("locks")
        try FileManager.default.createSymbolicLink(at: locks, withDestinationURL: target)
        #expect(throws: AgentLeasePathError.self) {
            _ = try AgentLeasePaths.open(selectedRoot: managedRoot.path)
        }
    }

    @Test("Concurrent creators converge on one safe layout")
    func concurrentCreation() throws {
        let parent = try makeAgentLeaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("state")
        let first = try launchAgentLeaseHelper(["prepare-state", root.path])
        let second = try launchAgentLeaseHelper(["prepare-state", root.path])
        first.process.waitUntilExit()
        second.process.waitUntilExit()

        #expect(first.process.terminationStatus == 0, "\(first.readOutput())")
        #expect(second.process.terminationStatus == 0, "\(second.readOutput())")
        _ = try AgentLeasePaths.open(selectedRoot: root.path)
    }
}
