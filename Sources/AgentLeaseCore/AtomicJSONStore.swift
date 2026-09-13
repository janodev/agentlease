import Darwin
import Foundation

public enum AtomicJSONStoreError: Error, Equatable, Sendable {
    case encoding(String)
    case invalidName(String)
    case systemCall(operation: String, errorNumber: Int32)

    public var failure: AgentLeaseFailure {
        switch self {
        case .encoding(let message):
            AgentLeaseFailure(
                kind: .recordPublication,
                operation: "encode",
                message: message
            )
        case .invalidName(let name):
            AgentLeaseFailure(
                kind: .recordPublication,
                operation: "validateRecordName",
                message: "invalid record name: \(name)"
            )
        case .systemCall(let operation, let errorNumber):
            AgentLeaseFailure(
                kind: .recordPublication,
                operation: operation,
                errorNumber: errorNumber,
                message: AgentLeaseFailure.systemMessage(for: errorNumber)
            )
        }
    }
}

public final class AtomicJSONStore: Sendable {
    enum FailurePoint: Equatable, Sendable {
        case directorySync
        case fileSync
        case rename
        case write
    }

    private let failurePoint: FailurePoint?
    private let paths: AgentLeasePaths

    public init(paths: AgentLeasePaths) {
        self.failurePoint = nil
        self.paths = paths
    }

    init(paths: AgentLeasePaths, failurePoint: FailurePoint?) {
        self.failurePoint = failurePoint
        self.paths = paths
    }

    public func replace<T: Encodable>(_ value: T, named name: String) throws {
        guard Self.isSafeRecordName(name) else {
            throw AtomicJSONStoreError.invalidName(name)
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(value)
        } catch {
            throw AtomicJSONStoreError.encoding(String(describing: error))
        }

        let temporaryName = ".\(name).\(UUID().uuidString).tmp"
        var descriptor = temporaryName.withCString { pointer in
            Darwin.openat(
                paths.runsDirectoryDescriptor,
                pointer,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else {
            throw AtomicJSONStoreError.systemCall(operation: "openat", errorNumber: errno)
        }

        var temporaryExists = true
        defer {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
            }
            if temporaryExists {
                _ = temporaryName.withCString { pointer in
                    Darwin.unlinkat(paths.runsDirectoryDescriptor, pointer, 0)
                }
            }
        }

        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            throw AtomicJSONStoreError.systemCall(operation: "fchmod", errorNumber: errno)
        }
        try inject(.write)
        try writeAll(data, to: descriptor)
        try inject(.fileSync)
        guard Darwin.fsync(descriptor) == 0 else {
            throw AtomicJSONStoreError.systemCall(operation: "fsyncFile", errorNumber: errno)
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw AtomicJSONStoreError.systemCall(operation: "close", errorNumber: errno)
        }
        descriptor = -1

        try inject(.rename)
        let renameResult = temporaryName.withCString { temporaryPointer in
            name.withCString { namePointer in
                Darwin.renameat(
                    paths.runsDirectoryDescriptor,
                    temporaryPointer,
                    paths.runsDirectoryDescriptor,
                    namePointer
                )
            }
        }
        guard renameResult == 0 else {
            throw AtomicJSONStoreError.systemCall(operation: "renameat", errorNumber: errno)
        }
        temporaryExists = false

        try inject(.directorySync)
        guard Darwin.fsync(paths.runsDirectoryDescriptor) == 0 else {
            throw AtomicJSONStoreError.systemCall(
                operation: "fsyncDirectory",
                errorNumber: errno
            )
        }
    }

    private func inject(_ point: FailurePoint) throws {
        guard failurePoint == point else { return }
        throw AtomicJSONStoreError.systemCall(
            operation: "injected\(String(describing: point).capitalized)",
            errorNumber: EIO
        )
    }

    private static func isSafeRecordName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.utf8.contains(0)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw AtomicJSONStoreError.systemCall(
                        operation: "write",
                        errorNumber: result == 0 ? EIO : errno
                    )
                }
            }
        }
    }
}
