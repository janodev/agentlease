@testable import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("Persistent file locks", .serialized)
struct FileLockTests {
    @Test("Acquired descriptors move above 64 and stay close-on-exec")
    func descriptorPolicyAndExplicitRelease() throws {
        let fixture = try LockFixture()
        defer { fixture.remove() }
        let resource = try ResourceName("example:descriptor")
        let lock = try FileLock(resource: resource, paths: fixture.paths)

        #expect(try lock.tryAcquire())
        let descriptor = try #require(lock.inheritedDescriptor)
        #expect(descriptor >= 64)
        #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)

        lock.release()
        #expect(lock.inheritedDescriptor == nil)
        #expect(fcntl(descriptor, F_GETFD) == -1)

        let path = fixture.lockPath(for: resource)
        #expect(FileManager.default.fileExists(atPath: path.path))
        let replacement = try FileLock(resource: resource, paths: fixture.paths)
        #expect(try replacement.tryAcquire())
        replacement.release()
    }

    @Test("Metadata is rewritten in place and bounded")
    func metadataWriteAndRead() throws {
        let fixture = try LockFixture()
        defer { fixture.remove() }
        let lock = try FileLock(
            resource: ResourceName("example:metadata"),
            paths: fixture.paths
        )
        #expect(try lock.tryAcquire())
        try lock.writeMetadata(Data("longer metadata".utf8))
        try lock.writeMetadata(Data("short".utf8))
        #expect(lock.readMetadata() == .data(Data("short".utf8)))
        #expect(throws: FileLockError.invalidMetadataSize(4_097)) {
            try lock.writeMetadata(Data(repeating: 0, count: 4_097))
        }
        lock.release()
    }

    @Test("Shared holders coexist and exclude exclusive holders")
    func sharedAndExclusiveCompatibility() throws {
        let fixture = try LockFixture()
        defer { fixture.remove() }
        let resource = try ResourceName("example:shared")
        let firstShared = try FileLock(resource: resource, mode: .shared, paths: fixture.paths)
        let secondShared = try FileLock(resource: resource, mode: .shared, paths: fixture.paths)
        let exclusive = try FileLock(resource: resource, paths: fixture.paths)

        #expect(try firstShared.tryAcquire())
        #expect(throws: FileLockError.metadataRequiresExclusive(resource.value)) {
            try firstShared.writeMetadata(Data("forbidden".utf8))
        }
        #expect(try secondShared.tryAcquire())
        #expect(try !exclusive.tryAcquire())
        firstShared.release()
        #expect(try !exclusive.tryAcquire())
        secondShared.release()
        #expect(try exclusive.tryAcquire())

        let blockedShared = try FileLock(resource: resource, mode: .shared, paths: fixture.paths)
        #expect(try !blockedShared.tryAcquire())
        exclusive.release()
        #expect(try blockedShared.tryAcquire())
        blockedShared.release()
    }

    @Test("Symlinks, directories, hard links, and unsafe modes fail closed")
    func rejectsUnsafeLockFiles() throws {
        try expectUnsafeLockPath(resourceValue: "unsafe:symlink") { fixture, resource in
            let target = fixture.root.appendingPathComponent("target")
            FileManager.default.createFile(atPath: target.path, contents: Data())
            try FileManager.default.createSymbolicLink(
                at: fixture.lockPath(for: resource),
                withDestinationURL: target
            )
        }
        try expectUnsafeLockPath(resourceValue: "unsafe:directory") { fixture, resource in
            try FileManager.default.createDirectory(
                at: fixture.lockPath(for: resource),
                withIntermediateDirectories: false
            )
        }
        try expectUnsafeLockPath(resourceValue: "unsafe:mode") { fixture, resource in
            let path = fixture.lockPath(for: resource)
            FileManager.default.createFile(atPath: path.path, contents: Data())
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: path.path
            )
        }
        try expectUnsafeLockPath(resourceValue: "unsafe:hardlink") { fixture, resource in
            let path = fixture.lockPath(for: resource)
            FileManager.default.createFile(atPath: path.path, contents: Data())
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path.path
            )
            let other = fixture.root.appendingPathComponent("other-link")
            guard link(path.path, other.path) == 0 else {
                throw AgentLeaseTestError.systemCall("link", errno)
            }
        }
    }

    private func expectUnsafeLockPath(
        resourceValue: String,
        prepare: (LockFixture, ResourceName) throws -> Void
    ) throws {
        let fixture = try LockFixture()
        defer { fixture.remove() }
        let resource = try ResourceName(resourceValue)
        try prepare(fixture, resource)
        let originalIdentity = try? FileManager.default.attributesOfItem(
            atPath: fixture.lockPath(for: resource).path
        )[.systemFileNumber] as? NSNumber

        #expect(throws: FileLockError.self) {
            _ = try FileLock(resource: resource, paths: fixture.paths)
        }
        let resultingIdentity = try? FileManager.default.attributesOfItem(
            atPath: fixture.lockPath(for: resource).path
        )[.systemFileNumber] as? NSNumber
        #expect(originalIdentity == resultingIdentity)
    }
}

struct LockFixture {
    let paths: AgentLeasePaths
    let root: URL

    init() throws {
        let parent = try makeAgentLeaseTemporaryDirectory()
        root = parent.appendingPathComponent("state")
        paths = try AgentLeasePaths.open(selectedRoot: root.path)
    }

    func lockPath(for resource: ResourceName) -> URL {
        root.appendingPathComponent("locks").appendingPathComponent(resource.lockFileName)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}
