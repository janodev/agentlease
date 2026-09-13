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

        let result = try await Subprocess.run(
            .path(.init(executablePath)),
            arguments: Arguments(
                executablePathOverride: executableArgument,
                remainingValues: Array(arguments.dropFirst())
            ),
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
}
