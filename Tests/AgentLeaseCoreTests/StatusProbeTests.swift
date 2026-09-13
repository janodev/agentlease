@testable import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("Kernel-backed status probes", .serialized)
struct StatusProbeTests {
    @Test("Held and free availability comes from flock without changing metadata or inode")
    func heldAndFree() throws {
        let parent = try makeAgentLeaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let paths = try AgentLeasePaths.open(
            selectedRoot: parent.appendingPathComponent("state").path
        )
        let resource = try ResourceName("status:held")
        let lock = try FileLock(resource: resource, paths: paths)
        #expect(try lock.tryAcquire())
        let metadata = validMetadata(resource: resource.value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try lock.writeMetadata(encoder.encode(metadata))
        let lockURL = URL(fileURLWithPath: paths.rootPath)
            .appendingPathComponent("locks")
            .appendingPathComponent(resource.lockFileName)
        let originalData = try Data(contentsOf: lockURL)
        let originalInode = try inode(at: lockURL)

        let held = StatusProbe.inspect(paths: paths)
        #expect(!held.requiresFailureExit)
        let heldEntry = try #require(held.report.entries.first)
        #expect(heldEntry.availability == .held)
        #expect(heldEntry.metadataStatus == .valid)
        #expect(heldEntry.resource == resource.value)
        #expect(heldEntry.lastOwner == metadata)
        #expect(heldEntry.error == nil)
        #expect(try Data(contentsOf: lockURL) == originalData)
        #expect(try inode(at: lockURL) == originalInode)

        lock.release()
        let free = StatusProbe.inspect(paths: paths)
        #expect(!free.requiresFailureExit)
        let freeEntry = try #require(free.report.entries.first)
        #expect(freeEntry.availability == .free)
        #expect(freeEntry.metadataStatus == .valid)
        #expect(freeEntry.lastOwner == metadata)
        #expect(try Data(contentsOf: lockURL) == originalData)
        #expect(try inode(at: lockURL) == originalInode)
    }

    @Test("Absent, corrupt, oversized, and mismatched metadata preserve kernel results")
    func diagnosticMetadataStates() throws {
        let parent = try makeAgentLeaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let paths = try AgentLeasePaths.open(
            selectedRoot: parent.appendingPathComponent("state").path
        )
        let absent = try ResourceName("status:absent")
        let invalid = try ResourceName("status:invalid")
        let oversized = try ResourceName("status:oversized")
        let mismatch = try ResourceName("status:mismatch")

        try FileLock(resource: absent, paths: paths).release()
        try writeMetadata(Data("{".utf8), resource: invalid, paths: paths)
        try writeMetadata(
            Data(repeating: 0x78, count: FileLock.maximumMetadataBytes + 1),
            resource: oversized,
            paths: paths
        )
        let mismatchedMetadata = validMetadata(resource: "status:different")
        try writeMetadata(
            JSONEncoder().encode(mismatchedMetadata),
            resource: mismatch,
            paths: paths
        )

        let result = StatusProbe.inspect(paths: paths)
        #expect(!result.requiresFailureExit)
        let entries = Dictionary(
            uniqueKeysWithValues: result.report.entries.compactMap { entry in
                entry.digest.map { ($0, entry) }
            }
        )
        #expect(entries[absent.lockDigest]?.availability == .free)
        #expect(entries[absent.lockDigest]?.metadataStatus == .absent)
        #expect(entries[absent.lockDigest]?.error == nil)
        #expect(entries[invalid.lockDigest]?.availability == .free)
        #expect(entries[invalid.lockDigest]?.metadataStatus == .invalid)
        #expect(entries[invalid.lockDigest]?.resource == nil)
        #expect(entries[invalid.lockDigest]?.error != nil)
        #expect(entries[oversized.lockDigest]?.availability == .free)
        #expect(entries[oversized.lockDigest]?.metadataStatus == .oversized)
        #expect(entries[mismatch.lockDigest]?.availability == .free)
        #expect(entries[mismatch.lockDigest]?.metadataStatus == .invalid)
        #expect(entries[mismatch.lockDigest]?.resource == nil)

        let data = try JSONEncoder().encode(result.report)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let jsonEntries = try #require(object["entries"] as? [[String: Any]])
        let absentJSON = try #require(
            jsonEntries.first(where: { $0["digest"] as? String == absent.lockDigest })
        )
        #expect(absentJSON["resource"] is NSNull)
        #expect(absentJSON["lastOwner"] is NSNull)
        #expect(absentJSON["error"] is NSNull)
    }

    @Test("Unexpected names and unsafe entry types are sorted, untouched, and fail status")
    func unexpectedEntries() throws {
        let parent = try makeAgentLeaseTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let paths = try AgentLeasePaths.open(
            selectedRoot: parent.appendingPathComponent("state").path
        )
        let locks = URL(fileURLWithPath: paths.rootPath).appendingPathComponent("locks")
        let unexpected = locks.appendingPathComponent("unexpected")
        _ = FileManager.default.createFile(atPath: unexpected.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: unexpected.path
        )
        let directoryName = try ResourceName("status:directory").lockFileName
        let directory = locks.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let symlinkName = try ResourceName("status:symlink").lockFileName
        let symlink = locks.appendingPathComponent(symlinkName)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unexpected)

        let result = StatusProbe.inspect(paths: paths)
        #expect(result.requiresFailureExit)
        #expect(result.report.errors.isEmpty)
        #expect(
            result.report.entries.map(\.fileName)
                == result.report.entries.map(\.fileName).sorted(by: utf8Precedes)
        )
        #expect(result.report.entries.count == 3)
        #expect(result.report.entries.allSatisfy { $0.availability == .unknown })
        #expect(result.report.entries.allSatisfy { $0.error != nil })
        #expect(FileManager.default.fileExists(atPath: unexpected.path))
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: symlink.path))
    }
}

private func inode(at url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
}

private func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}

private func validMetadata(resource: String) -> LockMetadata {
    LockMetadata(
        resourceName: resource,
        runID: UUID().uuidString,
        coordinatorPID: getpid(),
        childPID: nil,
        mode: .run,
        state: .running,
        label: "status test",
        bead: nil,
        acquiredAt: RunRecord.timestamp()
    )
}

private func writeMetadata(
    _ data: Data,
    resource: ResourceName,
    paths: AgentLeasePaths
) throws {
    let lock = try FileLock(resource: resource, paths: paths)
    #expect(try lock.tryAcquire())
    if data.count <= FileLock.maximumMetadataBytes {
        try lock.writeMetadata(data)
        lock.release()
        return
    }
    lock.release()
    let url = URL(fileURLWithPath: paths.rootPath)
        .appendingPathComponent("locks")
        .appendingPathComponent(resource.lockFileName)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: data)
    try handle.close()
}
