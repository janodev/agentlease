import Darwin
import Foundation
import Synchronization

public enum LeaseSetError: Error, Equatable, Sendable {
    case invalidWaitSeconds(Double)
    case resourceLimit(requested: Int, softLimit: UInt64)
    case timedOut(String)

    public var failure: AgentLeaseFailure {
        switch self {
        case .invalidWaitSeconds:
            AgentLeaseFailure(
                kind: .internal,
                operation: "validateWaitSeconds",
                message: "wait duration must be finite and nonnegative"
            )
        case .resourceLimit(let requested, let softLimit):
            AgentLeaseFailure(
                kind: .resourceLimit,
                operation: "getrlimit",
                message: "\(requested) resources do not fit under descriptor limit \(softLimit)"
            )
        case .timedOut(let resource):
            AgentLeaseFailure(
                kind: .acquisitionTimeout,
                operation: "flock",
                resource: resource,
                message: "timed out waiting for the resource"
            )
        }
    }
}

public struct MetadataWriteIssue: Equatable, Sendable {
    public let failure: AgentLeaseFailure
    public let resource: String

    public init(resource: String, failure: AgentLeaseFailure) {
        self.resource = resource
        self.failure = failure
    }
}

public final class LeaseSet: Sendable {
    /// `FileLock` values become reachable only through `Mutex` after initialization.
    /// No unprotected aliases escape this state container.
    private struct State: @unchecked Sendable {
        var locks: [FileLock]
        var metadataWriteIssues: [MetadataWriteIssue]
    }

    private let state: Mutex<State>

    private init(locks: [FileLock], metadataWriteIssues: [MetadataWriteIssue]) {
        state = Mutex(State(locks: locks, metadataWriteIssues: metadataWriteIssues))
    }

    deinit {
        release()
    }

    public var inheritedDescriptors: [Int32] {
        state.withLock { $0.locks.compactMap(\.inheritedDescriptor) }
    }

    public var metadataWriteIssues: [MetadataWriteIssue] {
        state.withLock { $0.metadataWriteIssues }
    }

    public var resources: [ResourceName] {
        state.withLock { $0.locks.map(\.resource) }
    }

    public static func acquire(
        _ resources: ResourceSet,
        paths: AgentLeasePaths,
        waitSeconds: Double?,
        initialMetadata: @Sendable (ResourceName) -> LockMetadata,
        onContention: @Sendable (ResourceName, BoundedMetadataRead) -> Void = { _, _ in }
    ) async throws -> LeaseSet {
        if let waitSeconds,
           !waitSeconds.isFinite || waitSeconds < 0 {
            throw LeaseSetError.invalidWaitSeconds(waitSeconds)
        }
        try checkDescriptorLimit(resourceCount: resources.resources.count)

        var openedLocks: [FileLock] = []
        do {
            for resource in resources.resources {
                openedLocks.append(try FileLock(resource: resource, paths: paths))
            }
        } catch {
            for lock in openedLocks.reversed() {
                lock.release()
            }
            throw error
        }

        let deadline = MonotonicDeadline(waitSeconds: waitSeconds)
        var acquiredCount = 0
        var metadataIssues: [MetadataWriteIssue] = []
        var didReportContention = false
        do {
            for lock in openedLocks {
                var attempts = 0
                while true {
                    try Task.checkCancellation()
                    if deadline.expiredBeforeAttempt(attempts: attempts) {
                        throw LeaseSetError.timedOut(lock.resource.value)
                    }
                    attempts += 1
                    if try lock.tryAcquire() {
                        acquiredCount += 1
                        if let issue = writeMetadata(
                            initialMetadata(lock.resource),
                            to: lock
                        ) {
                            metadataIssues.append(issue)
                        }
                        break
                    }

                    if !didReportContention {
                        didReportContention = true
                        onContention(lock.resource, lock.readMetadata())
                    }
                    guard let delay = deadline.pollingDelay else {
                        throw LeaseSetError.timedOut(lock.resource.value)
                    }
                    try await Task.sleep(for: delay)
                }
            }
            try Task.checkCancellation()
        } catch {
            for lock in openedLocks.prefix(acquiredCount).reversed() {
                lock.release()
            }
            for lock in openedLocks.dropFirst(acquiredCount) {
                lock.release()
            }
            throw error
        }

        return LeaseSet(locks: openedLocks, metadataWriteIssues: metadataIssues)
    }

    public func clearCloseOnExec() throws {
        try state.withLock { state in
            for lock in state.locks {
                try lock.clearCloseOnExec()
            }
        }
    }

    public func release() {
        state.withLock { state in
            for lock in state.locks.reversed() {
                lock.release()
            }
            state.locks.removeAll(keepingCapacity: false)
        }
    }

    public func takeMetadataWriteIssues() -> [MetadataWriteIssue] {
        state.withLock { state in
            let issues = state.metadataWriteIssues
            state.metadataWriteIssues.removeAll(keepingCapacity: true)
            return issues
        }
    }

    public func updateMetadata(
        _ metadata: @Sendable (ResourceName) -> LockMetadata
    ) {
        state.withLock { state in
            var transitionIssues: [MetadataWriteIssue] = []
            for lock in state.locks {
                if let issue = Self.writeMetadata(metadata(lock.resource), to: lock) {
                    transitionIssues.append(issue)
                }
            }
            state.metadataWriteIssues.append(contentsOf: transitionIssues)
        }
    }

    private static func checkDescriptorLimit(resourceCount: Int) throws {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            throw FileLockError.systemCall(
                operation: "getrlimit",
                resource: "",
                errorNumber: errno
            )
        }
        let softLimit = UInt64(limit.rlim_cur)
        let minimumRequired = UInt64(FileLock.minimumOwnedDescriptor) + UInt64(resourceCount)
        guard softLimit >= minimumRequired else {
            throw LeaseSetError.resourceLimit(requested: resourceCount, softLimit: softLimit)
        }
    }

    private static func writeMetadata(
        _ metadata: LockMetadata,
        to lock: FileLock
    ) -> MetadataWriteIssue? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try lock.writeMetadata(encoder.encode(metadata))
            return nil
        } catch let error as FileLockError {
            return MetadataWriteIssue(resource: lock.resource.value, failure: error.failure)
        } catch {
            return MetadataWriteIssue(
                resource: lock.resource.value,
                failure: AgentLeaseFailure(
                    kind: .lockIO,
                    operation: "encodeMetadata",
                    resource: lock.resource.value,
                    message: String(describing: error)
                )
            )
        }
    }
}

private struct MonotonicDeadline {
    private static let pollingNanoseconds: UInt64 = 25_000_000

    private let deadlineNanoseconds: UInt64?
    private let zeroWait: Bool

    init(waitSeconds: Double?) {
        guard let waitSeconds else {
            deadlineNanoseconds = nil
            zeroWait = false
            return
        }

        zeroWait = waitSeconds == 0
        let now = DispatchTime.now().uptimeNanoseconds
        let maximumDelta = UInt64.max - now
        let requestedNanoseconds = waitSeconds * 1_000_000_000
        let delta = requestedNanoseconds >= Double(maximumDelta)
            ? maximumDelta
            : UInt64(requestedNanoseconds)
        deadlineNanoseconds = now + delta
    }

    var pollingDelay: Duration? {
        if zeroWait { return nil }
        guard let remainingNanoseconds else {
            return .milliseconds(25)
        }
        guard remainingNanoseconds > 0 else { return nil }
        return .nanoseconds(Int64(min(Self.pollingNanoseconds, remainingNanoseconds)))
    }

    func expiredBeforeAttempt(attempts: Int) -> Bool {
        if zeroWait {
            return attempts > 0
        }
        guard let remainingNanoseconds else { return false }
        return remainingNanoseconds == 0
    }

    private var remainingNanoseconds: UInt64? {
        guard let deadlineNanoseconds else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= deadlineNanoseconds ? 0 : deadlineNanoseconds - now
    }
}
