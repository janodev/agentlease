import Darwin
import Foundation
import Subprocess

public struct ResolvedExecutable: Equatable, Sendable {
    public let original: String
    public let path: String

    public init(original: String, path: String) {
        self.original = original
        self.path = path
    }
}

public enum ExecutableResolutionError: Error, Equatable, Sendable {
    case notFound(path: String, errorNumber: Int32?)
    case notRunnable(path: String, errorNumber: Int32?)

    public var exitCode: Int32 {
        switch self {
        case .notFound:
            127
        case .notRunnable:
            126
        }
    }

    public var failure: AgentLeaseFailure {
        switch self {
        case .notFound(let path, let errorNumber):
            AgentLeaseFailure(
                kind: .executableNotFound,
                operation: "resolveExecutable",
                errorNumber: errorNumber,
                message: "executable not found: \(path)"
            )
        case .notRunnable(let path, let errorNumber):
            AgentLeaseFailure(
                kind: .executableNotRunnable,
                operation: "preflightExecutable",
                errorNumber: errorNumber,
                message: "executable is not a runnable regular file: \(path)"
            )
        }
    }
}

public enum ExecutableResolver {
    public static func resolve(
        _ command: String,
        workingDirectory: String,
        environment: [String: String]
    ) async throws -> ResolvedExecutable {
        let resolvedPath: String
        if command.contains("/") {
            resolvedPath = command.first == "/"
                ? lexicallyStandardizedAbsolutePath(command)
                : lexicallyStandardizedAbsolutePath("\(workingDirectory)/\(command)")
        } else {
            do {
                let subprocessEnvironment = Environment.custom(
                    environment.sorted(by: { $0.key < $1.key }).map { key, value in
                        Array("\(key)=\(value)\0".utf8)
                    }
                )
                resolvedPath = try await Executable.name(command)
                    .resolveExecutablePath(in: subprocessEnvironment)
                    .string
            } catch {
                throw ExecutableResolutionError.notFound(path: command, errorNumber: nil)
            }
        }

        try preflight(path: resolvedPath)
        return ResolvedExecutable(original: command, path: resolvedPath)
    }

    private static func lexicallyStandardizedAbsolutePath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default:
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private static func preflight(path: String) throws {
        var status = stat()
        let statusResult = path.withCString { pointer in
            stat(pointer, &status)
        }
        guard statusResult == 0 else {
            let statusError = errno
            if statusError == ENOENT || statusError == ENOTDIR {
                throw ExecutableResolutionError.notFound(
                    path: path,
                    errorNumber: statusError
                )
            }
            throw ExecutableResolutionError.notRunnable(
                path: path,
                errorNumber: statusError
            )
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw ExecutableResolutionError.notRunnable(path: path, errorNumber: nil)
        }

        let accessResult = path.withCString { pointer in
            Darwin.faccessat(AT_FDCWD, pointer, X_OK, AT_EACCESS)
        }
        guard accessResult == 0 else {
            throw ExecutableResolutionError.notRunnable(
                path: path,
                errorNumber: errno
            )
        }
    }
}
