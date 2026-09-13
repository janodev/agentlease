import Darwin
import Foundation

public enum AgentLeasePathError: Error, Equatable, Sendable {
    case invalidStateRoot(String)
    case systemCall(operation: String, path: String, errorNumber: Int32)
    case unsafeDirectory(path: String, reason: String)

    public var failure: AgentLeaseFailure {
        switch self {
        case .invalidStateRoot(let message):
            AgentLeaseFailure(
                kind: .unsafeState,
                operation: "resolveStateRoot",
                message: message
            )
        case .systemCall(let operation, let path, let errorNumber):
            AgentLeaseFailure(
                kind: .stateIO,
                operation: operation,
                errorNumber: errorNumber,
                message: "\(path): \(AgentLeaseFailure.systemMessage(for: errorNumber))"
            )
        case .unsafeDirectory(let path, let reason):
            AgentLeaseFailure(
                kind: .unsafeState,
                operation: "validateDirectory",
                message: "\(path): \(reason)"
            )
        }
    }
}

/// The three descriptors are immutable and remain open for the instance lifetime.
/// Callers cannot close or replace them, so sharing read-only descriptor identity is safe.
public final class AgentLeasePaths: @unchecked Sendable {
    public static let homeEnvironmentKey = "AGENTLEASE_HOME"

    let locksDirectoryDescriptor: Int32
    let rootDirectoryDescriptor: Int32
    public let rootPath: String
    let runsDirectoryDescriptor: Int32

    private init(
        rootPath: String,
        rootDirectoryDescriptor: Int32,
        locksDirectoryDescriptor: Int32,
        runsDirectoryDescriptor: Int32
    ) {
        self.rootPath = rootPath
        self.rootDirectoryDescriptor = rootDirectoryDescriptor
        self.locksDirectoryDescriptor = locksDirectoryDescriptor
        self.runsDirectoryDescriptor = runsDirectoryDescriptor
    }

    deinit {
        _ = Darwin.close(runsDirectoryDescriptor)
        _ = Darwin.close(locksDirectoryDescriptor)
        _ = Darwin.close(rootDirectoryDescriptor)
    }

    public static func open(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AgentLeasePaths {
        try open(selectedRoot: selectedRoot(environment: environment))
    }

    static func selectedRoot(environment: [String: String]) throws -> String {
        let selectedRoot: String
        if let explicitRoot = environment[homeEnvironmentKey] {
            guard !explicitRoot.isEmpty else {
                throw AgentLeasePathError.invalidStateRoot(
                    "AGENTLEASE_HOME must not be empty"
                )
            }
            selectedRoot = explicitRoot
        } else {
            selectedRoot = try effectiveUserHomeDirectory() + "/.agentlease"
        }
        return selectedRoot
    }

    public static func open(selectedRoot: String) throws -> AgentLeasePaths {
        guard selectedRoot.first == "/", !selectedRoot.utf8.contains(0) else {
            throw AgentLeasePathError.invalidStateRoot(
                "state root must be a nonempty absolute path"
            )
        }

        let standardized = lexicallyStandardizedAbsolutePath(selectedRoot)
        guard standardized != "/" else {
            throw AgentLeasePathError.invalidStateRoot(
                "state root must have a final path component"
            )
        }
        let rootURL = URL(fileURLWithPath: standardized, isDirectory: true)
        let finalComponent = rootURL.lastPathComponent
        let parentPath = rootURL.deletingLastPathComponent().path
        let canonicalParent = try canonicalDirectoryPath(parentPath)
        let canonicalRoot = canonicalParent == "/"
            ? "/\(finalComponent)"
            : "\(canonicalParent)/\(finalComponent)"

        let parentDescriptor = try openDirectory(path: canonicalParent)
        defer { _ = Darwin.close(parentDescriptor) }

        let rootDescriptor = try createAndOpenDirectory(
            named: finalComponent,
            parentDescriptor: parentDescriptor,
            displayPath: canonicalRoot
        )
        var keepRoot = false
        defer {
            if !keepRoot {
                _ = Darwin.close(rootDescriptor)
            }
        }

        let locksPath = canonicalRoot + "/locks"
        let locksDescriptor = try createAndOpenDirectory(
            named: "locks",
            parentDescriptor: rootDescriptor,
            displayPath: locksPath
        )
        var keepLocks = false
        defer {
            if !keepLocks {
                _ = Darwin.close(locksDescriptor)
            }
        }

        let runsPath = canonicalRoot + "/runs"
        let runsDescriptor = try createAndOpenDirectory(
            named: "runs",
            parentDescriptor: rootDescriptor,
            displayPath: runsPath
        )

        keepRoot = true
        keepLocks = true
        return AgentLeasePaths(
            rootPath: canonicalRoot,
            rootDirectoryDescriptor: rootDescriptor,
            locksDirectoryDescriptor: locksDescriptor,
            runsDirectoryDescriptor: runsDescriptor
        )
    }

    private static func canonicalDirectoryPath(_ path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = path.withCString { pointer in
            Darwin.realpath(pointer, &buffer)
        }
        guard result != nil else {
            throw AgentLeasePathError.systemCall(
                operation: "realpath",
                path: path,
                errorNumber: errno
            )
        }
        let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(
            decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private static func createAndOpenDirectory(
        named name: String,
        parentDescriptor: Int32,
        displayPath: String
    ) throws -> Int32 {
        var created = false
        let creationResult = name.withCString { pointer in
            Darwin.mkdirat(parentDescriptor, pointer, 0o700)
        }
        if creationResult == 0 {
            created = true
        } else if errno != EEXIST {
            throw AgentLeasePathError.systemCall(
                operation: "mkdirat",
                path: displayPath,
                errorNumber: errno
            )
        }

        if created {
            let modeResult = name.withCString { pointer in
                Darwin.fchmodat(parentDescriptor, pointer, 0o700, AT_SYMLINK_NOFOLLOW)
            }
            guard modeResult == 0 else {
                throw AgentLeasePathError.systemCall(
                    operation: "fchmodat",
                    path: displayPath,
                    errorNumber: errno
                )
            }
        }

        let descriptor = name.withCString { pointer in
            Darwin.openat(
                parentDescriptor,
                pointer,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw AgentLeasePathError.systemCall(
                operation: "openat",
                path: displayPath,
                errorNumber: errno
            )
        }
        do {
            if created, Darwin.fchmod(descriptor, 0o700) != 0 {
                throw AgentLeasePathError.systemCall(
                    operation: "fchmod",
                    path: displayPath,
                    errorNumber: errno
                )
            }
            try validateDirectory(descriptor: descriptor, path: displayPath)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func effectiveUserHomeDirectory() throws -> String {
        let userID = geteuid()
        let configuredSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        let bufferSize = max(configuredSize > 0 ? Int(configuredSize) : 16_384, 1_024)
        var buffer = [CChar](repeating: 0, count: bufferSize)
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let code = getpwuid_r(userID, &entry, &buffer, buffer.count, &result)
        guard code == 0, let result, let home = result.pointee.pw_dir else {
            throw AgentLeasePathError.systemCall(
                operation: "getpwuid_r",
                path: "effective user \(userID)",
                errorNumber: code == 0 ? ENOENT : code
            )
        }
        return String(cString: home)
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

    private static func openDirectory(path: String) throws -> Int32 {
        let descriptor = path.withCString { pointer in
            Darwin.open(pointer, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw AgentLeasePathError.systemCall(
                operation: "open",
                path: path,
                errorNumber: errno
            )
        }
        return descriptor
    }

    private static func validateDirectory(descriptor: Int32, path: String) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw AgentLeasePathError.systemCall(
                operation: "fstat",
                path: path,
                errorNumber: errno
            )
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw AgentLeasePathError.unsafeDirectory(path: path, reason: "not a directory")
        }
        guard status.st_uid == geteuid() else {
            throw AgentLeasePathError.unsafeDirectory(
                path: path,
                reason: "not owned by the effective user"
            )
        }
        guard status.st_mode & 0o777 == 0o700 else {
            throw AgentLeasePathError.unsafeDirectory(path: path, reason: "mode is not 0700")
        }
    }
}
