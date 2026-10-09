@testable import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("Coordinated registry retention", .serialized)
struct RegistryRetentionTests {
    @Test("Preopened waiters exclude retirement until acquisition, without blocking unrelated resources")
    func pendingOpenAndRecreation() async throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let resource = try ResourceName("retention:queued")
        let unrelated = try ResourceName("retention:unrelated")
        let owner = try FileLock(resource: resource, paths: fixture.paths)
        defer { owner.release() }
        try #require(try owner.tryAcquire())
        let waiter = try FileLock(resource: resource, paths: fixture.paths)
        defer { waiter.release() }
        #expect(try !waiter.tryAcquire())
        try fixture.age(fixture.lockURL(resource))
        let originalInode = try fixture.inode(fixture.lockURL(resource))
        let gate = try fixture.openGate()
        defer { _ = Darwin.close(gate) }
        let gateInode = try fixture.inode(fixture.gateURL)

        let gateResult = flock(gate, LOCK_EX | LOCK_NB)
        let gateError = errno
        #expect(gateResult == -1)
        #expect(gateError == EWOULDBLOCK || gateError == EAGAIN)
        let busy = try LeaseCleanup.perform(
            paths: fixture.paths, options: CleanupOptions(execute: true), now: fixture.now
        )
        #expect(busy.busy)
        #expect(busy.removedCount == 0)
        #expect(try fixture.inode(fixture.lockURL(resource)) == originalInode)

        let independent = try launchAgentLeaseHelper([
            "probe-lease", fixture.paths.rootPath, unrelated.value,
        ])
        defer { terminateIfRunning(independent) }
        try await waitForExit(independent)
        #expect(independent.process.terminationStatus == 0, "⚠️ \(independent.readOutput())")
        try fixture.age(fixture.lockURL(unrelated))

        owner.release()
        // The waiter has an open inode but has not acquired flock yet.
        #expect(flock(gate, LOCK_EX | LOCK_NB) == -1)
        #expect(try LeaseCleanup.perform(
            paths: fixture.paths, options: CleanupOptions(execute: true), now: fixture.now
        ).busy)
        try #require(try waiter.tryAcquire())
        try fixture.age(fixture.lockURL(resource))
        // Concurrent suites can fork while this fixture's close-on-exec claim is
        // open. Wait for their exec boundary, while a leaked claim still fails.
        try await waitForExclusiveRegistryProbe(gate)
        try #require(flock(gate, LOCK_UN) == 0)

        let cleaned = try LeaseCleanup.perform(
            paths: fixture.paths, options: CleanupOptions(execute: true), now: fixture.now
        )
        #expect(!cleaned.busy)
        #expect(fixture.exists(fixture.lockURL(resource)))
        #expect(!fixture.exists(fixture.lockURL(unrelated)))
        #expect(try fixture.inode(fixture.lockURL(resource)) == originalInode)

        waiter.release()
        _ = try LeaseCleanup.perform(
            paths: fixture.paths, options: CleanupOptions(execute: true), now: fixture.now
        )
        #expect(!fixture.exists(fixture.lockURL(resource)))
        let replacement = try FileLock(resource: resource, paths: fixture.paths)
        defer { replacement.release() }
        try #require(try replacement.tryAcquire())
        let contested = try launchAgentLeaseHelper([
            "probe-lease", fixture.paths.rootPath, resource.value,
        ])
        defer { terminateIfRunning(contested) }
        try await waitForExit(contested)
        #expect(contested.process.terminationStatus == 75, "⚠️ \(contested.readOutput())")
        #expect(try fixture.inode(fixture.gateURL) == gateInode)
    }

    @Test("Shared and exclusive holders retain every record referencing their resource", arguments: [LeaseMode.shared, .exclusive])
    func heldResourcesProtectHistoricalRuns(mode: LeaseMode) throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let resource = try ResourceName("retention:held")
        let holder = try FileLock(resource: resource, mode: mode, paths: fixture.paths)
        defer { holder.release() }
        try #require(try holder.tryAcquire())
        try fixture.age(fixture.lockURL(resource))
        let record = try fixture.record(resources: [resource.value])

        let result = try LeaseCleanup.perform(
            paths: fixture.paths, options: CleanupOptions(execute: true), now: fixture.now
        )
        #expect(!result.busy)
        #expect(result.errors.isEmpty)
        #expect(fixture.exists(fixture.lockURL(resource)))
        #expect(fixture.exists(record))

        holder.release()
        _ = try LeaseCleanup.perform(
            paths: fixture.paths, options: CleanupOptions(execute: true), now: fixture.now
        )
        #expect(!fixture.exists(fixture.lockURL(resource)))
        #expect(!fixture.exists(record))
    }

    @Test("Retention uses completed time and live coordinator identity rather than stale file age alone")
    func recordRetention() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let old = try fixture.record(resources: ["retention:old"])
        let recentCompletion = try fixture.record(
            resources: ["retention:recent"], finishedAt: fixture.now.addingTimeInterval(-60)
        )
        let active = try fixture.record(
            resources: ["retention:active"], state: .acquiring, coordinatorPID: getpid(),
            finishedAt: nil
        )
        let recentResource = try ResourceName("retention:recent-lock")
        let recentLock = try FileLock(resource: recentResource, paths: fixture.paths)
        try #require(try recentLock.tryAcquire())
        recentLock.release()
        let originalRecent = try Data(contentsOf: recentCompletion)
        let preview = try LeaseCleanup.perform(paths: fixture.paths, now: fixture.now)
        #expect(preview.eligibleCount == 1)
        #expect(preview.removedCount == 0)
        #expect(fixture.exists(old))

        let result = try LeaseCleanup.perform(
            paths: fixture.paths, options: CleanupOptions(execute: true), now: fixture.now
        )
        #expect(result.removedCount == 1)
        #expect(!fixture.exists(old))
        #expect(fixture.exists(active))
        #expect(fixture.exists(fixture.lockURL(recentResource)))
        #expect(try Data(contentsOf: recentCompletion) == originalRecent)
    }

    @Test("Malformed records and unsafe entries remain untouched and report errors")
    func unsafeEntriesFailClosed() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let target = fixture.parent.appendingPathComponent("outside")
        try Data("outside fixture target".utf8).write(to: target)
        let symlink = fixture.lockURL(try ResourceName("retention:symlink"))
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let hardlink = try fixture.idle("retention:hardlink")
        let otherLink = fixture.parent.appendingPathComponent("other-link")
        try #require(link(hardlink.path, otherLink.path) == 0)
        let unsafeMode = try fixture.idle("retention:mode")
        try #require(chmod(unsafeMode.path, 0o644) == 0)
        let foreign = fixture.root.appendingPathComponent("locks/unexpected-entry")
        try fixture.write(Data(), at: foreign)
        let malformed = fixture.root.appendingPathComponent("runs/\(UUID().uuidString).json")
        try fixture.write(Data("{".utf8), at: malformed)
        let runSymlink = fixture.root.appendingPathComponent("runs/\(UUID().uuidString).json")
        try FileManager.default.createSymbolicLink(at: runSymlink, withDestinationURL: target)
        let directory = fixture.lockURL(try ResourceName("retention:directory"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let untouched = [symlink, hardlink, unsafeMode, foreign, malformed, runSymlink, directory]
        let identities = try untouched.map(fixture.inode)

        let result = try LeaseCleanup.perform(
            paths: fixture.paths, options: CleanupOptions(execute: true), now: fixture.now
        )
        #expect(!result.errors.isEmpty)
        #expect(result.removedCount == 0)
        #expect(try untouched.map(fixture.inode) == identities)
        #expect(try Data(contentsOf: target) == Data("outside fixture target".utf8))
    }

    @Test("Explicit evidence keep sets survive execution and automatic cleanup is throttled for one day")
    func keepAndDailyThrottle() throws {
        let fixture = try RetentionFixture()
        defer { fixture.remove() }
        let protected = try ResourceName("retention:protected")
        let keptLock = try fixture.idle(protected.value)
        let keptRun = try fixture.record(resources: [protected.value])
        let keptRunID = keptRun.deletingPathExtension().lastPathComponent
        let result = try LeaseCleanup.perform(
            paths: fixture.paths,
            options: CleanupOptions(
                execute: true, protectedLockDigests: [protected.lockDigest],
                protectedRunIDs: [keptRunID]
            ), now: fixture.now
        )
        #expect(result.removedCount == 0)
        #expect(fixture.exists(keptLock))
        #expect(fixture.exists(keptRun))

        let environment = [
            "AGENTLEASE_AUTO_CLEANUP": "1",
            "AGENTLEASE_CLEANUP_KEEP_LOCK_DIGESTS": protected.lockDigest,
        ]
        let first = try fixture.idle("retention:daily-first")
        #expect(try LeaseCleanup.automatic(paths: fixture.paths, environment: [:], now: fixture.now) == nil)
        #expect(fixture.exists(first))
        #expect(throws: AgentLeaseFailure.self) {
            _ = try LeaseCleanup.automatic(
                paths: fixture.paths,
                environment: [
                    "AGENTLEASE_AUTO_CLEANUP": "1",
                    "AGENTLEASE_CLEANUP_KEEP_LOCK_DIGESTS": "invalid-digest",
                ], now: fixture.now
            )
        }
        #expect(fixture.exists(first))
        let pending = try FileLock(resource: ResourceName("retention:daily-pending"), paths: fixture.paths)
        let busy = try #require(try LeaseCleanup.automatic(
            paths: fixture.paths, environment: environment, now: fixture.now
        ))
        #expect(busy.busy)
        #expect(!fixture.exists(fixture.root.appendingPathComponent(LeaseCleanup.automaticStampFileName)))
        pending.release()
        let automatic = try #require(try LeaseCleanup.automatic(
            paths: fixture.paths, environment: environment, now: fixture.now
        ))
        #expect(!automatic.throttled)
        #expect(!fixture.exists(first))
        #expect(fixture.exists(keptLock))
        let second = try fixture.idle("retention:daily-second")
        let throttled = try #require(try LeaseCleanup.automatic(
            paths: fixture.paths, environment: environment,
            now: fixture.now.addingTimeInterval(60)
        ))
        #expect(throttled.throttled)
        #expect(fixture.exists(second))
        _ = try LeaseCleanup.automatic(
            paths: fixture.paths, environment: environment,
            now: fixture.now.addingTimeInterval(86_401)
        )
        #expect(!fixture.exists(second))
        #expect(fixture.exists(keptLock))
    }
}

private func waitForExclusiveRegistryProbe(_ descriptor: Int32) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while clock.now < deadline {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
        let code = errno
        guard code == EWOULDBLOCK || code == EAGAIN else {
            throw AgentLeaseTestError.systemCall("flock(registry probe)", code)
        }
        try await clock.sleep(for: .milliseconds(10))
    }
    throw AgentLeaseTestError.markerTimeout("exclusive registry probe after pending acquisition")
}

private struct RetentionFixture {
    let parent: URL
    let paths: AgentLeasePaths
    let now = Date()

    var root: URL { URL(fileURLWithPath: paths.rootPath) }
    var gateURL: URL { root.appendingPathComponent(RegistryGate.fileName) }
    var old: Date { now.addingTimeInterval(-8 * 86_400) }

    init() throws {
        parent = try makeAgentLeaseTemporaryDirectory()
        paths = try AgentLeasePaths.open(selectedRoot: parent.appendingPathComponent("state").path)
    }

    func lockURL(_ resource: ResourceName) -> URL {
        root.appendingPathComponent("locks/\(resource.lockFileName)")
    }

    func idle(_ value: String) throws -> URL {
        let resource = try ResourceName(value)
        let lock = try FileLock(resource: resource, paths: paths)
        try #require(try lock.tryAcquire())
        lock.release()
        let url = lockURL(resource)
        try age(url)
        return url
    }

    func record(
        resources: [String], state: RunState = .exited, coordinatorPID: Int32 = Int32.max,
        finishedAt: Date? = Date().addingTimeInterval(-8 * 86_400)
    ) throws -> URL {
        let id = UUID().uuidString
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let record = RunRecord(
            runID: id, mode: .run, state: state, resources: resources,
            label: nil, bead: nil, coordinatorPID: coordinatorPID, childPID: nil,
            workingDirectory: parent.path, executable: "/usr/bin/true",
            resolvedExecutable: "/usr/bin/true", argumentCommitment: String(repeating: "0", count: 64),
            arguments: nil, startedAt: format.format(old),
            finishedAt: finishedAt.map(format.format), receivedSignal: nil,
            termination: state == .exited ? RunTermination(kind: .exit, value: 0) : nil,
            failure: nil
        )
        try AtomicJSONStore(paths: paths).replace(record, named: "\(id).json")
        let url = root.appendingPathComponent("runs/\(id).json")
        try age(url)
        return url
    }

    func write(_ data: Data, at url: URL) throws {
        try data.write(to: url)
        try #require(chmod(url.path, 0o600) == 0)
        try age(url)
    }

    func age(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func inode(_ url: URL) throws -> UInt64 {
        var status = stat()
        try #require(lstat(url.path, &status) == 0)
        return UInt64(status.st_ino)
    }

    func openGate() throws -> Int32 {
        let descriptor = Darwin.open(gateURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        return descriptor
    }

    func remove() { try? FileManager.default.removeItem(at: parent) }
}
