import AgentLeaseCore
import Darwin

enum DirectProcessReplacementError: Error, Sendable {
    case allocation(operation: String)
    case systemCall(errorNumber: Int32)

    var exitCode: Int32 {
        switch self {
        case .allocation:
            return 70
        case .systemCall(let errorNumber):
            if errorNumber == ENOENT || errorNumber == ENOTDIR {
                return 127
            }
            if errorNumber == EACCES || errorNumber == EPERM || errorNumber == ENOEXEC {
                return 126
            }
            return 70
        }
    }

    var failure: AgentLeaseFailure {
        switch self {
        case .allocation(let operation):
            return AgentLeaseFailure(
                kind: .internal,
                operation: operation,
                errorNumber: ENOMEM,
                message: AgentLeaseFailure.systemMessage(for: ENOMEM)
            )
        case .systemCall(let errorNumber):
            let kind: AgentLeaseFailure.Kind
            if errorNumber == ENOENT || errorNumber == ENOTDIR {
                kind = .executableNotFound
            } else if errorNumber == EACCES || errorNumber == EPERM || errorNumber == ENOEXEC {
                kind = .executableNotRunnable
            } else if errorNumber == E2BIG {
                kind = .environment
            } else {
                kind = .exec
            }
            return AgentLeaseFailure(
                kind: kind,
                operation: "execve",
                errorNumber: errorNumber,
                message: AgentLeaseFailure.systemMessage(for: errorNumber)
            )
        }
    }
}

enum DirectProcessReplacement {
    static func replace(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws {
        let argumentVector = try CStringVector(
            arguments,
            allocationOperation: "allocateArguments"
        )
        let environmentVector = try CStringVector(
            environment.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" },
            allocationOperation: "allocateEnvironment"
        )
        try ProcessSignalState.restoreInheritedMask()

        let errorNumber = executablePath.withCString { executable in
            argumentVector.withUnsafeMutablePointer { arguments in
                environmentVector.withUnsafeMutablePointer { environment in
                    _ = Darwin.execve(executable, arguments, environment)
                    return errno
                }
            }
        }
        throw DirectProcessReplacementError.systemCall(errorNumber: errorNumber)
    }
}

private final class CStringVector {
    private let storage: [UnsafeMutablePointer<CChar>]

    init(_ values: [String], allocationOperation: String) throws {
        var allocated: [UnsafeMutablePointer<CChar>] = []
        do {
            for value in values {
                guard let pointer = strdup(value) else {
                    throw DirectProcessReplacementError.allocation(
                        operation: allocationOperation
                    )
                }
                allocated.append(pointer)
            }
            storage = allocated
        } catch {
            for pointer in allocated {
                free(pointer)
            }
            throw error
        }
    }

    deinit {
        for pointer in storage {
            free(pointer)
        }
    }

    func withUnsafeMutablePointer<Result>(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = storage + [nil]
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}
