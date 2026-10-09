import AgentLeaseCore
import ArgumentParser
import Darwin
import Foundation

struct ExecCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Acquire resources and replace AgentLease with one command."
    )

    @OptionGroup var options: ExecutionOptions

    mutating func run() async throws {
        let result = await ExecExecutor(options: options).execute()
        if result != 0 {
            throw ExitCode(result)
        }
    }
}

private struct ExecExecutor: Sendable {
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

        // Maintenance runs before any acquisition claim and never blocks on busy work.
        do {
            _ = try LeaseCleanup.automatic(paths: paths, environment: inheritedEnvironment)
        } catch {
            stderr("automatic cleanup skipped: \(error)")
        }

        let baseChildEnvironment = ChildEnvironment.build(
            inherited: inheritedEnvironment,
            stateRoot: paths.rootPath,
            runID: runID,
            resources: resources,
            bead: options.bead
        )
        let startedAt = RunRecord.timestamp()
        let publication = RunRecordPublication(
            initialRecord: RunRecord(
                runID: runID,
                mode: .exec,
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
            ),
            store: AtomicJSONStore(paths: paths)
        )
        let admissionStarted = DispatchTime.now().uptimeNanoseconds
        let acquisitionClaim: RegistryClaim
        do {
            acquisitionClaim = try await RegistryGate.shared(paths: paths, waitSeconds: options.waitSeconds)
        } catch {
            let classified = classify(error)
            stderr(classified.failure.description)
            return classified.exitCode
        }
        defer { acquisitionClaim.release() }

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
            mode: .exec,
            runID: runID
        )
        let lease: LeaseSet
        do {
            lease = try await LeaseSet.acquire(
                resources,
                paths: paths,
                waitSeconds: try remainingAcquisitionWait(options.waitSeconds, since: admissionStarted),
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
                metadata: metadata
            )
        }
        acquisitionClaim.release()
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
                metadata: metadata
            )
        }

        do {
            try publication.publishAcquired()
        } catch {
            return finishFailure(
                error,
                lease: lease,
                publication: publication,
                metadata: metadata
            )
        }
        lease.updateMetadata { lease in
            metadata.value(lease: lease, state: .acquired, childPID: nil)
        }
        reportMetadataIssues(lease)
        stderr("acquired resources: \(resources.environmentValue)")

        do {
            try lease.clearCloseOnExec()
            try publication.publishHandoffPrepared()
        } catch {
            return finishFailure(
                error,
                lease: lease,
                publication: publication,
                metadata: metadata
            )
        }
        lease.updateMetadata { lease in
            metadata.value(lease: lease, state: .handoffPrepared, childPID: nil)
        }
        reportMetadataIssues(lease)

        do {
            try DirectProcessReplacement.replace(
                executablePath: resolvedExecutable.path,
                arguments: options.command,
                environment: childEnvironment
            )
            return 70
        } catch {
            return finishFailure(
                error,
                lease: lease,
                publication: publication,
                metadata: metadata
            )
        }
    }

    private func finishFailure(
        _ error: any Error,
        lease: LeaseSet?,
        publication: RunRecordPublication,
        metadata: MetadataContext
    ) -> Int32 {
        let classified = classify(error)
        stderr(classified.failure.description)

        var publicationFailed = false
        do {
            try publication.publishFailure(
                state: .failed,
                failure: classified.failure,
                receivedSignal: nil
            )
        } catch {
            publicationFailed = true
            stderr("could not publish failure record: \(error)")
        }
        if let lease {
            lease.updateMetadata { lease in
                metadata.value(lease: lease, state: .failed, childPID: nil)
            }
            reportMetadataIssues(lease)
            lease.release()
        }
        return publicationFailed ? 70 : classified.exitCode
    }

    private func classify(
        _ error: any Error
    ) -> (failure: AgentLeaseFailure, exitCode: Int32) {
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
        if let error = error as? AgentLeaseFailure {
            return (error, 70)
        }
        if let error = error as? AtomicJSONStoreError {
            return (error.failure, 70)
        }
        if let error = error as? InheritedLeaseManifestError {
            return (error.failure, 70)
        }
        if let error = error as? DirectProcessReplacementError {
            return (error.failure, error.exitCode)
        }
        return (
            AgentLeaseFailure(
                kind: .internal,
                operation: "execPreparation",
                message: String(describing: error)
            ),
            70
        )
    }
}
