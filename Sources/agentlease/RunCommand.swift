import AgentLeaseCore
import ArgumentParser
import Darwin
import Foundation
import Synchronization

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Acquire resources and supervise one noninteractive command."
    )

    @OptionGroup var options: ExecutionOptions

    mutating func run() async throws {
        let result = await RunExecutor(options: options).execute()
        if result != 0 {
            throw ExitCode(result)
        }
    }
}

private struct RunExecutor: Sendable {
    private enum Event: Sendable {
        case completed(Int32)
        case relayEnded
        case signal(Int32)
    }

    let options: ExecutionOptions

    func execute() async -> Int32 {
        let inheritedEnvironment = ProcessInfo.processInfo.environment
        if ChildEnvironment.isNested(environment: inheritedEnvironment) {
            stderr("nested run and exec invocations are not allowed")
            return 70
        }

        let resources: ResourceSet
        do {
            resources = try ResourceSet(options.resource)
        } catch {
            stderr(String(describing: error))
            return 64
        }

        let workingDirectory = FileManager.default.currentDirectoryPath
        let resolvedExecutable: ResolvedExecutable
        do {
            resolvedExecutable = try await ExecutableResolver.resolve(
                options.command[0],
                workingDirectory: workingDirectory,
                environment: inheritedEnvironment
            )
        } catch let error as ExecutableResolutionError {
            stderr(error.failure.description)
            return error.exitCode
        } catch {
            stderr(String(describing: error))
            return 70
        }

        let runID = UUID().uuidString
        let paths: AgentLeasePaths
        do {
            paths = try AgentLeasePaths.open(environment: inheritedEnvironment)
        } catch let error as AgentLeasePathError {
            stderr(error.failure.description)
            return 70
        } catch {
            stderr(String(describing: error))
            return 70
        }

        let childEnvironment = ChildEnvironment.build(
            inherited: inheritedEnvironment,
            stateRoot: paths.rootPath,
            runID: runID,
            resources: resources,
            bead: options.bead
        )
        let startedAt = RunRecord.timestamp()
        let record = RunRecord(
            runID: runID,
            mode: .run,
            state: .acquiring,
            resources: resources.resources.map(\.value),
            label: options.label,
            bead: options.bead,
            coordinatorPID: getpid(),
            childPID: nil,
            workingDirectory: workingDirectory,
            executable: options.command[0],
            resolvedExecutable: resolvedExecutable.path,
            argumentCommitment: ArgumentCommitment.digest(arguments: options.command),
            arguments: options.recordArguments ? options.command : nil,
            startedAt: startedAt,
            finishedAt: nil,
            receivedSignal: nil,
            termination: nil,
            failure: nil
        )
        let publication = RunRecordPublication(
            initialRecord: record,
            store: AtomicJSONStore(paths: paths)
        )

        let relay: SignalRelay
        do {
            relay = try SignalRelay()
        } catch {
            stderr("could not install signal relay: \(error)")
            return 70
        }
        defer { relay.restore() }

        do {
            try publication.publishInitial()
        } catch {
            stderr("could not publish acquiring record: \(error)")
            return 70
        }

        let metadata = MetadataContext(
            acquiredAt: startedAt,
            bead: options.bead,
            coordinatorPID: getpid(),
            label: options.label,
            runID: runID
        )
        return await withTaskGroup(of: Event.self) { group in
            group.addTask {
                .completed(
                    await executeLifecycle(
                        resources: resources,
                        paths: paths,
                        resolvedExecutable: resolvedExecutable,
                        childEnvironment: childEnvironment,
                        publication: publication,
                        metadata: metadata,
                        relay: relay
                    )
                )
            }
            group.addTask {
                if let signalNumber = await relay.nextSignal() {
                    return .signal(signalNumber)
                }
                return .relayEnded
            }

            var signalResult: Int32?
            while let event = await group.next() {
                switch event {
                case .completed(let result):
                    group.cancelAll()
                    return signalResult ?? result
                case .relayEnded:
                    continue
                case .signal(let signalNumber):
                    signalResult = 128 + signalNumber
                    group.cancelAll()
                }
            }
            return signalResult ?? 70
        }
    }

    private func executeLifecycle(
        resources: ResourceSet,
        paths: AgentLeasePaths,
        resolvedExecutable: ResolvedExecutable,
        childEnvironment: [String: String],
        publication: RunRecordPublication,
        metadata: MetadataContext,
        relay: SignalRelay
    ) async -> Int32 {
        let lease: LeaseSet
        do {
            lease = try await LeaseSet.acquire(
                resources,
                paths: paths,
                waitSeconds: options.waitSeconds,
                initialMetadata: { resource in
                    metadata.value(resource: resource, state: .acquiring, childPID: nil)
                },
                onContention: reportContention
            )
        } catch {
            return finishFailure(
                error,
                lease: nil,
                publication: publication,
                metadata: metadata,
                relay: relay
            )
        }
        reportMetadataIssues(lease)

        do {
            try publication.publishAcquired()
        } catch {
            return finishFailure(
                error,
                lease: lease,
                publication: publication,
                metadata: metadata,
                relay: relay
            )
        }
        lease.updateMetadata { resource in
            metadata.value(resource: resource, state: .acquired, childPID: nil)
        }
        reportMetadataIssues(lease)
        stderr("acquired resources: \(resources.environmentValue)")

        let result: SupervisedProcessResult
        let startedProcess = StartedProcessIdentifier()
        do {
            result = try await SupervisedSubprocess.run(
                executablePath: resolvedExecutable.path,
                arguments: options.command,
                environment: childEnvironment,
                inheritedDescriptors: lease.inheritedDescriptors
            ) { childPID in
                startedProcess.set(childPID)
                try publication.publishRunning(childPID: childPID)
                lease.updateMetadata { resource in
                    metadata.value(resource: resource, state: .running, childPID: childPID)
                }
                reportMetadataIssues(lease)
            }
        } catch {
            return finishFailure(
                error,
                lease: lease,
                publication: publication,
                metadata: metadata,
                relay: relay,
                childPID: startedProcess.value
            )
        }

        if let receivedSignal = relay.firstSignal {
            return finishReceivedSignal(
                receivedSignal,
                lease: lease,
                publication: publication,
                metadata: metadata,
                childPID: result.processIdentifier
            )
        }

        let state: RunState
        let termination: RunTermination
        let childResult: Int32
        switch result.termination {
        case .exited(let status):
            state = .exited
            termination = RunTermination(kind: .exit, value: status)
            childResult = status
        case .signaled(let signalNumber):
            state = .signalled
            termination = RunTermination(kind: .signal, value: signalNumber)
            childResult = 128 + signalNumber
        }

        var publicationFailed = false
        do {
            try publication.publishTerminal(state: state, termination: termination)
        } catch {
            publicationFailed = true
            stderr("could not publish terminal record: \(error)")
        }
        lease.updateMetadata { resource in
            metadata.value(resource: resource, state: state, childPID: result.processIdentifier)
        }
        reportMetadataIssues(lease)
        lease.release()
        if publicationFailed, childResult == 0 {
            return 70
        }
        return childResult
    }

    private func finishFailure(
        _ error: any Error,
        lease: LeaseSet?,
        publication: RunRecordPublication,
        metadata: MetadataContext,
        relay: SignalRelay,
        childPID: Int32? = nil
    ) -> Int32 {
        let receivedSignal = relay.firstSignal
        let state: RunState = receivedSignal == nil ? .failed : .signalled
        let classified = classify(error, receivedSignal: receivedSignal)
        stderr(classified.failure.description)

        var publicationFailed = false
        do {
            try publication.publishFailure(
                state: state,
                failure: receivedSignal == nil ? classified.failure : nil,
                receivedSignal: receivedSignal,
                childPID: childPID
            )
        } catch {
            publicationFailed = true
            stderr("could not publish failure record: \(error)")
        }
        if let lease {
            lease.updateMetadata { resource in
                metadata.value(resource: resource, state: state, childPID: childPID)
            }
            reportMetadataIssues(lease)
            lease.release()
        }
        if let receivedSignal {
            return 128 + receivedSignal
        }
        return publicationFailed ? 70 : classified.exitCode
    }

    private func finishReceivedSignal(
        _ signalNumber: Int32,
        lease: LeaseSet,
        publication: RunRecordPublication,
        metadata: MetadataContext,
        childPID: Int32
    ) -> Int32 {
        do {
            try publication.publishFailure(
                state: .signalled,
                failure: nil,
                receivedSignal: signalNumber,
                childPID: childPID
            )
        } catch {
            stderr("could not publish signal outcome: \(error)")
        }
        lease.updateMetadata { resource in
            metadata.value(resource: resource, state: .signalled, childPID: childPID)
        }
        reportMetadataIssues(lease)
        lease.release()
        return 128 + signalNumber
    }

    private func classify(
        _ error: any Error,
        receivedSignal: Int32?
    ) -> (failure: AgentLeaseFailure, exitCode: Int32) {
        if let receivedSignal {
            return (
                AgentLeaseFailure(
                    kind: .cancelled,
                    operation: "signalRelay",
                    message: "received signal \(receivedSignal)"
                ),
                128 + receivedSignal
            )
        }
        if error is CancellationError {
            return (
                AgentLeaseFailure(
                    kind: .cancelled,
                    operation: "taskCancellation",
                    message: "operation was cancelled"
                ),
                70
            )
        }
        if let error = error as? LeaseSetError {
            return (error.failure, error.failure.kind == .acquisitionTimeout ? 75 : 70)
        }
        if let error = error as? FileLockError {
            return (error.failure, 70)
        }
        if let error = error as? AtomicJSONStoreError {
            return (error.failure, 70)
        }
        let launch = SupervisedSubprocess.classifyLaunchError(error)
        return (launch.failure, launch.exitCode)
    }
}

private struct MetadataContext: Sendable {
    let acquiredAt: String
    let bead: String?
    let coordinatorPID: Int32
    let label: String?
    let runID: String

    func value(
        resource: ResourceName,
        state: RunState,
        childPID: Int32?
    ) -> LockMetadata {
        LockMetadata(
            resourceName: resource.value,
            runID: runID,
            coordinatorPID: coordinatorPID,
            childPID: childPID,
            mode: .run,
            state: state,
            label: label,
            bead: bead,
            acquiredAt: acquiredAt
        )
    }
}

private final class StartedProcessIdentifier: Sendable {
    private let processIdentifier = Mutex<Int32?>(nil)

    var value: Int32? {
        processIdentifier.withLock { $0 }
    }

    func set(_ value: Int32) {
        processIdentifier.withLock { $0 = value }
    }
}

private final class RunRecordPublication: Sendable {
    private let fileName: String
    private let record: Mutex<RunRecord>
    private let store: AtomicJSONStore

    init(initialRecord: RunRecord, store: AtomicJSONStore) {
        fileName = "\(initialRecord.runID).json"
        record = Mutex(initialRecord)
        self.store = store
    }

    func publishAcquired() throws {
        try update { record in
            record.state = .acquired
        }
    }

    func publishFailure(
        state: RunState,
        failure: AgentLeaseFailure?,
        receivedSignal: Int32?,
        childPID: Int32? = nil
    ) throws {
        try update { record in
            record.state = state
            if let childPID {
                record.childPID = childPID
            }
            record.finishedAt = RunRecord.timestamp()
            record.receivedSignal = receivedSignal
            record.termination = nil
            record.failure = failure
        }
    }

    func publishInitial() throws {
        try record.withLock { record in
            try store.replace(record, named: fileName)
        }
    }

    func publishRunning(childPID: Int32) throws {
        try update { record in
            record.state = .running
            record.childPID = childPID
        }
    }

    func publishTerminal(state: RunState, termination: RunTermination) throws {
        try update { record in
            record.state = state
            record.finishedAt = RunRecord.timestamp()
            record.termination = termination
            record.failure = nil
        }
    }

    private func update(_ mutation: (inout RunRecord) -> Void) throws {
        try record.withLock { record in
            var candidate = record
            mutation(&candidate)
            try store.replace(candidate, named: fileName)
            record = candidate
        }
    }
}

private func reportContention(
    resource: ResourceName,
    metadataRead: BoundedMetadataRead
) {
    var owner = ""
    if case .data(let data) = metadataRead,
       let metadata = try? JSONDecoder().decode(LockMetadata.self, from: data),
       metadata.resourceName == resource.value {
        let label = metadata.label.map { " label=\($0)" } ?? ""
        owner = " (last owner run=\(metadata.runID)\(label))"
    }
    stderr("waiting for resource \(resource.value)\(owner)")
}

private func reportMetadataIssues(_ lease: LeaseSet) {
    let issues = lease.takeMetadataWriteIssues()
    guard let first = issues.first else { return }
    stderr(
        "metadata update failed for \(issues.count) resource(s); "
            + "first: \(first.failure.description)"
    )
}

private func stderr(_ message: String) {
    let sanitized = AgentLeaseFailure.bounded(AgentLeaseFailure.sanitized(message))
    FileHandle.standardError.write(Data("agentlease: \(sanitized)\n".utf8))
}
