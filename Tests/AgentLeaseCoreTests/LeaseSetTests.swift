@testable import AgentLeaseCore
import Darwin
import Foundation
import Testing

@Suite("Ordered lease sets", .serialized)
struct LeaseSetTests {
    @Test("Same resources serialize while different resources overlap")
    func contentionAndIndependence() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.remove() }
        let owner = try fixture.launchHolder(resources: ["shared"], suffix: "owner")
        defer { terminateIfRunning(owner.process) }
        try await waitForMarker(at: owner.ready, processes: [owner.process])

        let sharedProbe = try launchAgentLeaseHelper([
            "probe-lease", fixture.root.path, "shared",
        ])
        sharedProbe.process.waitUntilExit()
        #expect(sharedProbe.process.terminationStatus == 75, "\(sharedProbe.readOutput())")

        let independentProbe = try launchAgentLeaseHelper([
            "probe-lease", fixture.root.path, "independent",
        ])
        independentProbe.process.waitUntilExit()
        #expect(independentProbe.process.terminationStatus == 0, "\(independentProbe.readOutput())")

        try makeMarker(at: owner.release)
        owner.process.process.waitUntilExit()
        #expect(owner.process.process.terminationStatus == 0, "\(owner.process.readOutput())")

        let releasedProbe = try launchAgentLeaseHelper([
            "probe-lease", fixture.root.path, "shared",
        ])
        releasedProbe.process.waitUntilExit()
        #expect(releasedProbe.process.terminationStatus == 0, "\(releasedProbe.readOutput())")
    }

    @Test("Opposite request order converges without deadlock")
    func sortedMultiLockOrder() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.remove() }
        let start = fixture.root.deletingLastPathComponent().appendingPathComponent("start")
        let first = try fixture.launchHolder(
            resources: ["a", "b"],
            suffix: "first",
            start: start
        )
        let second = try fixture.launchHolder(
            resources: ["b", "a"],
            suffix: "second",
            start: start
        )
        defer {
            terminateIfRunning(first.process)
            terminateIfRunning(second.process)
        }
        try makeMarker(at: start)

        let firstReady = try await waitForEitherMarker(
            first.ready,
            second.ready,
            processes: [first.process, second.process]
        )
        let winner = firstReady == first.ready ? first : second
        let follower = firstReady == first.ready ? second : first
        try makeMarker(at: winner.release)
        winner.process.process.waitUntilExit()
        #expect(winner.process.process.terminationStatus == 0, "\(winner.process.readOutput())")

        try await waitForMarker(at: follower.ready, processes: [follower.process])
        try makeMarker(at: follower.release)
        follower.process.process.waitUntilExit()
        #expect(follower.process.process.terminationStatus == 0, "\(follower.process.readOutput())")
    }

    @Test("Cancellation while waiting for the second resource releases the first")
    func partialAcquisitionCleanup() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.remove() }
        let secondOwner = try fixture.launchHolder(resources: ["b"], suffix: "b-owner")
        defer { terminateIfRunning(secondOwner.process) }
        try await waitForMarker(at: secondOwner.ready, processes: [secondOwner.process])

        let paths = try AgentLeasePaths.open(selectedRoot: fixture.root.path)
        let resources = try ResourceSet(["b", "a"])
        let task = Task {
            let lease = try await LeaseSet.acquire(
                resources,
                paths: paths,
                waitSeconds: nil,
                initialMetadata: fixture.metadata
            )
            lease.release()
        }
        defer { task.cancel() }

        try await fixture.waitForMetadata(resource: "a", runID: "lease-test")
        let blockedProbe = try launchAgentLeaseHelper([
            "probe-lease", fixture.root.path, "a",
        ])
        blockedProbe.process.waitUntilExit()
        #expect(blockedProbe.process.terminationStatus == 75, "\(blockedProbe.readOutput())")

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled acquisition unexpectedly succeeded")
        } catch is CancellationError {
            // Expected cancellation at the polling sleep or retry boundary.
        } catch {
            Issue.record("expected CancellationError, received \(error)")
        }

        let releasedProbe = try launchAgentLeaseHelper([
            "probe-lease", fixture.root.path, "a",
        ])
        releasedProbe.process.waitUntilExit()
        #expect(releasedProbe.process.terminationStatus == 0, "\(releasedProbe.readOutput())")
        try makeMarker(at: secondOwner.release)
        secondOwner.process.process.waitUntilExit()
    }

    @Test("Zero wait probes once and huge finite deadlines do not overflow")
    func deadlineEdges() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.remove() }
        let paths = try AgentLeasePaths.open(selectedRoot: fixture.root.path)

        let free = try await LeaseSet.acquire(
            ResourceSet(["free"]),
            paths: paths,
            waitSeconds: 0,
            initialMetadata: fixture.metadata
        )
        free.release()

        let huge = try await LeaseSet.acquire(
            ResourceSet(["huge"]),
            paths: paths,
            waitSeconds: Double.greatestFiniteMagnitude,
            initialMetadata: fixture.metadata
        )
        huge.release()
    }

    @Test("Acquisition writes bounded diagnostic metadata")
    func acquisitionMetadata() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.remove() }
        let paths = try AgentLeasePaths.open(selectedRoot: fixture.root.path)
        let lease = try await LeaseSet.acquire(
            ResourceSet(["metadata"]),
            paths: paths,
            waitSeconds: 0,
            initialMetadata: fixture.metadata
        )
        let file = fixture.lockPath(resource: try ResourceName("metadata"))
        let metadata = try JSONDecoder().decode(
            LockMetadata.self,
            from: Data(contentsOf: file)
        )
        #expect(metadata.resourceName == "metadata")
        #expect(metadata.runID == "lease-test")
        #expect(lease.metadataWriteIssues.isEmpty)
        lease.release()
    }

    @Test("Owned lock descriptors survive only the selected spawn inheritance path")
    func supervisedDescriptorInheritance() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.remove() }
        let paths = try AgentLeasePaths.open(selectedRoot: fixture.root.path)
        let lease = try await LeaseSet.acquire(
            ResourceSet(["inherited"]),
            paths: paths,
            waitSeconds: 0,
            initialMetadata: fixture.metadata
        )
        defer { lease.release() }
        let descriptor = try #require(lease.inheritedDescriptors.first)
        let helper = try agentLeaseHelperPath()

        let result = try await SupervisedSubprocess.run(
            executablePath: helper,
            arguments: [helper, "check-descriptor", String(descriptor)],
            inheritedDescriptors: lease.inheritedDescriptors
        )

        #expect(result.termination == .exited(0))
        #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
    }
}

private struct LeaseFixture: Sendable {
    struct Holder {
        let process: HelperProcess
        let ready: URL
        let release: URL
    }

    let root: URL

    init() throws {
        root = try makeAgentLeaseTemporaryDirectory().appendingPathComponent("state")
    }

    func launchHolder(
        resources: [String],
        suffix: String,
        start: URL? = nil
    ) throws -> Holder {
        let parent = root.deletingLastPathComponent()
        let ready = parent.appendingPathComponent("ready-\(suffix)")
        let release = parent.appendingPathComponent("release-\(suffix)")
        let command: [String]
        if let start {
            command = [
                "hold-lease-after-start", root.path, start.path, ready.path, release.path,
            ] + resources
        } else {
            command = ["hold-lease", root.path, ready.path, release.path] + resources
        }
        return Holder(process: try launchAgentLeaseHelper(command), ready: ready, release: release)
    }

    func lockPath(resource: ResourceName) -> URL {
        root.appendingPathComponent("locks").appendingPathComponent(resource.lockFileName)
    }

    func metadata(resource: ResourceName) -> LockMetadata {
        LockMetadata(
            resourceName: resource.value,
            runID: "lease-test",
            coordinatorPID: getpid(),
            childPID: nil,
            mode: .run,
            state: .acquiring,
            label: nil,
            bead: nil,
            acquiredAt: RunRecord.timestamp()
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func waitForMetadata(
        resource: String,
        runID: String,
        timeout: Duration = .seconds(5)
    ) async throws {
        let path = lockPath(resource: try ResourceName(resource))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let data = try? Data(contentsOf: path),
               let metadata = try? JSONDecoder().decode(LockMetadata.self, from: data),
               metadata.runID == runID {
                return
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        throw AgentLeaseTestError.markerTimeout("metadata for \(resource)")
    }
}
