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
            resources = try ResourceSet(
                exclusive: options.resource,
                shared: options.sharedResource
            )
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

        let baseChildEnvironment = ChildEnvironment.build(
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
            resourceLeases: resources.leases,
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
            mode: .run,
            runID: runID
        )
        return await withTaskGroup(of: Event.self) { group in
            group.addTask {
                .completed(
                    await executeLifecycle(
                        resources: resources,
                        paths: paths,
                        resolvedExecutable: resolvedExecutable,
                        baseChildEnvironment: baseChildEnvironment,
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
        baseChildEnvironment: [String: String],
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
                initialMetadata: { lease in
                    metadata.value(lease: lease, state: .acquiring, childPID: nil)
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

        let childEnvironment: [String: String]
        do {
            childEnvironment = try ChildEnvironment.addingLeaseDescriptorManifest(
                lease.inheritedLeaseDescriptors,
                to: baseChildEnvironment
            )
        } catch {
            return finishFailure(
                error,
                lease: lease,
                publication: publication,
                metadata: metadata,
                relay: relay
            )
        }

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
        lease.updateMetadata { lease in
            metadata.value(lease: lease, state: .acquired, childPID: nil)
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
                lease.updateMetadata { lease in
                    metadata.value(lease: lease, state: .running, childPID: childPID)
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
        lease.updateMetadata { lease in
            metadata.value(lease: lease, state: state, childPID: result.processIdentifier)
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
            lease.updateMetadata { lease in
                metadata.value(lease: lease, state: state, childPID: childPID)
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
        lease.updateMetadata { lease in
            metadata.value(lease: lease, state: .signalled, childPID: childPID)
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
        if let error = error as? InheritedLeaseManifestError {
            return (error.failure, 70)
        }
        let launch = SupervisedSubprocess.classifyLaunchError(error)
        return (launch.failure, launch.exitCode)
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
