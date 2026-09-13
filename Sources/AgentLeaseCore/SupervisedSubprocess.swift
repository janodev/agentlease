import Darwin
import Subprocess

public enum SupervisedSubprocessError: Error, Equatable, Sendable {
    case emptyArguments
    case descriptorInheritanceFailed(descriptor: Int32, code: Int32)
    case sessionConfigurationFailed(operation: String, code: Int32)
}

public enum SupervisedTermination: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
}

public struct SupervisedProcessResult: Equatable, Sendable {
    public let processIdentifier: Int32
    public let termination: SupervisedTermination

    public init(processIdentifier: Int32, termination: SupervisedTermination) {
        self.processIdentifier = processIdentifier
        self.termination = termination
    }
}

public struct SupervisedLaunchError: Equatable, Sendable {
    public let exitCode: Int32
    public let failure: AgentLeaseFailure

    public init(exitCode: Int32, failure: AgentLeaseFailure) {
        self.exitCode = exitCode
        self.failure = failure
    }
}

public enum SupervisedSubprocess {
    public static let teardownSequence: [TeardownStep] = [
        .send(
            signal: .interrupt,
            toProcessGroup: true,
            allowedDurationToNextStep: .seconds(2)
        ),
        .gracefulShutDown(
            toProcessGroup: true,
            allowedDurationToNextStep: .seconds(5)
        ),
    ]

    public static func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        inheritedDescriptors: [Int32] = [],
        onStart: @escaping @Sendable (Int32) async throws -> Void = { _ in }
    ) async throws -> SupervisedProcessResult {
        guard let executableArgument = arguments.first else {
            throw SupervisedSubprocessError.emptyArguments
        }
        try Task.checkCancellation()

        let descriptorValues = inheritedDescriptors
        var platformOptions = PlatformOptions()
        platformOptions.teardownSequence = teardownSequence
        platformOptions.preSpawnProcessConfigurator = { spawnAttributes, fileActions in
            var flags: Int16 = 0
            let getFlagsResult = posix_spawnattr_getflags(&spawnAttributes, &flags)
            guard getFlagsResult == 0 else {
                throw SupervisedSubprocessError.sessionConfigurationFailed(
                    operation: "posix_spawnattr_getflags",
                    code: getFlagsResult
                )
            }
            let setFlagsResult = posix_spawnattr_setflags(
                &spawnAttributes,
                flags | Int16(POSIX_SPAWN_SETSID)
            )
            guard setFlagsResult == 0 else {
                throw SupervisedSubprocessError.sessionConfigurationFailed(
                    operation: "posix_spawnattr_setflags",
                    code: setFlagsResult
                )
            }

            var defaultSignals = sigset_t()
            let getDefaultsResult = posix_spawnattr_getsigdefault(
                &spawnAttributes,
                &defaultSignals
            )
            guard getDefaultsResult == 0 else {
                throw SupervisedSubprocessError.sessionConfigurationFailed(
                    operation: "posix_spawnattr_getsigdefault",
                    code: getDefaultsResult
                )
            }
            for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
                guard sigaddset(&defaultSignals, signalNumber) == 0 else {
                    throw SupervisedSubprocessError.sessionConfigurationFailed(
                        operation: "sigaddset",
                        code: errno
                    )
                }
            }
            let setDefaultsResult = posix_spawnattr_setsigdefault(
                &spawnAttributes,
                &defaultSignals
            )
            guard setDefaultsResult == 0 else {
                throw SupervisedSubprocessError.sessionConfigurationFailed(
                    operation: "posix_spawnattr_setsigdefault",
                    code: setDefaultsResult
                )
            }

            var signalMask = sigset_t()
            let getMaskResult = posix_spawnattr_getsigmask(&spawnAttributes, &signalMask)
            guard getMaskResult == 0 else {
                throw SupervisedSubprocessError.sessionConfigurationFailed(
                    operation: "posix_spawnattr_getsigmask",
                    code: getMaskResult
                )
            }
            for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
                guard sigdelset(&signalMask, signalNumber) == 0 else {
                    throw SupervisedSubprocessError.sessionConfigurationFailed(
                        operation: "sigdelset",
                        code: errno
                    )
                }
            }
            let setMaskResult = posix_spawnattr_setsigmask(
                &spawnAttributes,
                &signalMask
            )
            guard setMaskResult == 0 else {
                throw SupervisedSubprocessError.sessionConfigurationFailed(
                    operation: "posix_spawnattr_setsigmask",
                    code: setMaskResult
                )
            }

            for descriptor in descriptorValues {
                let result = posix_spawn_file_actions_addinherit_np(
                    &fileActions,
                    descriptor
                )
                guard result == 0 else {
                    throw SupervisedSubprocessError.descriptorInheritanceFailed(
                        descriptor: descriptor,
                        code: result
                    )
                }
            }
        }

        let subprocessEnvironment: Environment = environment.map { values in
            .custom(values.sorted(by: { $0.key < $1.key }).map { key, value in
                Array("\(key)=\(value)\0".utf8)
            })
        } ?? .inherit
        let result = try await Subprocess.run(
            .path(.init(executablePath)),
            arguments: Arguments(
                executablePathOverride: executableArgument,
                remainingValues: Array(arguments.dropFirst())
            ),
            environment: subprocessEnvironment,
            platformOptions: platformOptions,
            input: .none,
            output: .currentStandardOutput,
            error: .currentStandardError
        ) { execution in
            try await onStart(execution.processIdentifier.value)
        }
        try Task.checkCancellation()

        let termination: SupervisedTermination = switch result.terminationStatus {
        case .exited(let code):
            .exited(code)
        case .signaled(let signal):
            .signaled(signal)
        }
        return SupervisedProcessResult(
            processIdentifier: result.processIdentifier.value,
            termination: termination
        )
    }

    public static func classifyLaunchError(_ error: any Error) -> SupervisedLaunchError {
        if let subprocessError = error as? SubprocessError {
            let errorNumber = subprocessError.underlyingError?.rawValue
            if errorNumber == ENOENT || errorNumber == ENOTDIR {
                return SupervisedLaunchError(
                    exitCode: 127,
                    failure: AgentLeaseFailure(
                        kind: .executableNotFound,
                        operation: "spawn",
                        errorNumber: errorNumber,
                        message: subprocessError.description
                    )
                )
            }
            if errorNumber == EACCES || errorNumber == EPERM || errorNumber == ENOEXEC {
                return SupervisedLaunchError(
                    exitCode: 126,
                    failure: AgentLeaseFailure(
                        kind: .executableNotRunnable,
                        operation: "spawn",
                        errorNumber: errorNumber,
                        message: subprocessError.description
                    )
                )
            }
            return SupervisedLaunchError(
                exitCode: 70,
                failure: AgentLeaseFailure(
                    kind: .spawn,
                    operation: "spawn",
                    errorNumber: errorNumber,
                    message: subprocessError.description
                )
            )
        }
        return SupervisedLaunchError(
            exitCode: 70,
            failure: AgentLeaseFailure(
                kind: .spawn,
                operation: "spawnConfiguration",
                message: String(describing: error)
            )
        )
    }
}
