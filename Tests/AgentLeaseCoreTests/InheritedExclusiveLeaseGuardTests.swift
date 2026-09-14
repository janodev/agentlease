@testable import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("Inherited exclusive lease guard", .serialized)
struct InheritedExclusiveLeaseGuardTests {
    @Test("An unlocked inherited descriptor becomes exclusively owned")
    func establishesExclusiveOwnershipOnTheInheritedDescription() throws {
        let fixture = try LockFixture()
        defer { fixture.remove() }
        let resource = try ResourceName("guard:exclusive")
        let descriptor = try inheritedDescriptor(at: canonicalLockPath(
            fixture: fixture,
            resource: resource
        ))
        defer { _ = close(descriptor) }

        try InheritedExclusiveLeaseGuard.establish(
            resource: resource.value,
            environment: try environment(
                fixture: fixture,
                resource: resource,
                descriptor: descriptor,
                mode: .exclusive
            )
        )

        let contender = try FileLock(resource: resource, paths: fixture.paths)
        #expect(try !contender.tryAcquire())
        contender.release()
    }

    @Test("Mode mismatch refuses before changing the inherited description")
    func rejectsModeMismatchBeforeFlock() throws {
        let fixture = try LockFixture()
        defer { fixture.remove() }
        let resource = try ResourceName("guard:mismatched-mode")
        let descriptor = try inheritedDescriptor(at: canonicalLockPath(
            fixture: fixture,
            resource: resource
        ))
        defer { _ = close(descriptor) }
        let environment = try environment(
            fixture: fixture,
            resource: resource,
            descriptor: descriptor,
            mode: .shared
        )

        #expect(throws: InheritedExclusiveLeaseGuardError.leaseMismatch) {
            try InheritedExclusiveLeaseGuard.establish(
                resource: resource.value,
                environment: environment
            )
        }
        let contender = try FileLock(resource: resource, paths: fixture.paths)
        #expect(try contender.tryAcquire())
        contender.release()
    }

    private func environment(
        fixture: LockFixture,
        resource: ResourceName,
        descriptor: Int32,
        mode: LeaseMode
    ) throws -> [String: String] {
        let lease = InheritedLeaseDescriptor(
            resource: resource.value,
            mode: mode,
            descriptor: descriptor,
            path: canonicalLockPath(
                fixture: fixture,
                resource: resource
            ).path
        )
        return [
            AgentLeasePaths.homeEnvironmentKey: fixture.root.path,
            ChildEnvironment.heldResourcesKey: resource.value,
            InheritedLeaseManifest.environmentKey: try InheritedLeaseManifest(
                leases: [lease]
            ).environmentValue(),
        ]
    }

    private func canonicalLockPath(
        fixture: LockFixture,
        resource: ResourceName
    ) -> URL {
        URL(fileURLWithPath: fixture.paths.rootPath)
            .appendingPathComponent("locks")
            .appendingPathComponent(resource.lockFileName)
    }

    private func inheritedDescriptor(at path: URL) throws -> Int32 {
        let opened = open(path.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard opened >= 0 else {
            throw AgentLeaseTestError.systemCall("open", errno)
        }
        defer { _ = close(opened) }
        let inherited = fcntl(
            opened,
            F_DUPFD_CLOEXEC,
            FileLock.minimumOwnedDescriptor
        )
        guard inherited >= FileLock.minimumOwnedDescriptor else {
            throw AgentLeaseTestError.systemCall("fcntl", errno)
        }
        return inherited
    }
}
