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
        try await waitForExit(sharedProbe)
        #expect(sharedProbe.process.terminationStatus == 75, "\(sharedProbe.readOutput())")

        let independentProbe = try launchAgentLeaseHelper([
            "probe-lease", fixture.root.path, "independent",
        ])
        try await waitForExit(independentProbe)
        #expect(independentProbe.process.terminationStatus == 0, "\(independentProbe.readOutput())")

        try makeMarker(at: owner.release)
        try await waitForExit(owner.process)
        #expect(owner.process.process.terminationStatus == 0, "\(owner.process.readOutput())")

        let releasedProbe = try launchAgentLeaseHelper([
            "probe-lease", fixture.root.path, "shared",
        ])
        try await waitForExit(releasedProbe)
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
        try await waitForExit(winner.process)
        #expect(winner.process.process.terminationStatus == 0, "\(winner.process.readOutput())")

        try await waitForMarker(at: follower.ready, processes: [follower.process])
        try makeMarker(at: follower.release)
        try await waitForExit(follower.process)
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
        try await waitForExit(blockedProbe)
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
        try await waitForExit(releasedProbe)
        #expect(releasedProbe.process.terminationStatus == 0, "\(releasedProbe.readOutput())")
        try makeMarker(at: secondOwner.release)
        try await waitForExit(secondOwner.process)
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

    @Test("A positive deadline covers the whole set and releases earlier resources")
    func positiveDeadlineCoversSet() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.remove() }
        let owner = try fixture.launchHolder(resources: ["b"], suffix: "deadline-owner")
        defer { terminateIfRunning(owner.process) }
        try await waitForMarker(at: owner.ready, processes: [owner.process])
        let paths = try AgentLeasePaths.open(selectedRoot: fixture.root.path)
        let clock = ContinuousClock()
        let start = clock.now

        do {
            _ = try await LeaseSet.acquire(
                ResourceSet(["b", "a"]),
                paths: paths,
                waitSeconds: 0.1,
                initialMetadata: fixture.metadata
            )
            Issue.record("positive deadline unexpectedly acquired the busy set")
        } catch let error as LeaseSetError {
            #expect(error == .timedOut("b"))
        }
        #expect(start.duration(to: clock.now) < .seconds(1))

        let releasedProbe = try launchAgentLeaseHelper([
            "probe-lease", fixture.root.path, "a",
        ])
        try await waitForExit(releasedProbe)
        #expect(releasedProbe.process.terminationStatus == 0, "\(releasedProbe.readOutput())")
        try makeMarker(at: owner.release)
        try await waitForExit(owner.process)
    }

    @Test("Metadata failures remain observable without blocking launch or changing its result")
    func metadataFailureIsBestEffort() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.remove() }
        let paths = try AgentLeasePaths.open(selectedRoot: fixture.root.path)
        let injectedFailure = FileLockError.systemCall(
            operation: "injectedMetadataWrite",
            resource: "metadata-failure",
            errorNumber: EIO
        )
        let lease = try await LeaseSet.acquire(
            ResourceSet(["metadata-failure"]),
            paths: paths,
            waitSeconds: 0,
            initialMetadata: fixture.metadata,
            metadataWriteFailure: injectedFailure
        )
        defer { lease.release() }
        #expect(lease.takeMetadataWriteIssues().count == 1)

        let parent = fixture.root.deletingLastPathComponent()
        let started = parent.appendingPathComponent("metadata-child-started")
        let release = parent.appendingPathComponent("metadata-child-release")
        let helper = try agentLeaseHelperPath()
        let task = Task {
            try await SupervisedSubprocess.run(
                executablePath: helper,
                arguments: [
                    helper,
                    "wait-for-marker-and-exit",
                    release.path,
                    "23",
                ],
                inheritedDescriptors: lease.inheritedDescriptors
            ) { _ in
                try makeMarker(at: started)
            }
        }
        defer { task.cancel() }
        try await waitForMarker(at: started)

        let heldProbe = try launchAgentLeaseHelper([
            "probe-lease", fixture.root.path, "metadata-failure",
        ])
        try await waitForExit(heldProbe)
        #expect(heldProbe.process.terminationStatus == 75, "\(heldProbe.readOutput())")
        lease.updateMetadata { resource in
            fixture.metadata(resource: resource).replacing(state: .running)
        }
        #expect(lease.takeMetadataWriteIssues().count == 1)

        try makeMarker(at: release)
        let result = try await task.value
        #expect(result.termination == .exited(23))
        lease.updateMetadata { resource in
            fixture.metadata(resource: resource).replacing(state: .exited)
        }
        #expect(lease.takeMetadataWriteIssues().count == 1)
        lease.release()

        let freeProbe = try launchAgentLeaseHelper([
            "probe-lease", fixture.root.path, "metadata-failure",
        ])
        try await waitForExit(freeProbe)
        #expect(freeProbe.process.terminationStatus == 0, "\(freeProbe.readOutput())")
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
