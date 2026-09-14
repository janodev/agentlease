import Darwin
import Foundation

public enum FileLockError: Error, Equatable, Sendable {
    case alreadyAcquired(String)
    case invalidMetadataSize(Int)
    case metadataRequiresExclusive(String)
    case released(String)
    case systemCall(operation: String, resource: String, errorNumber: Int32)
    case unsafeFile(resource: String, reason: String)

    public var failure: AgentLeaseFailure {
        switch self {
        case .alreadyAcquired(let resource):
            AgentLeaseFailure(
                kind: .internal,
                operation: "flock",
                resource: resource,
                message: "lock has already been acquired"
            )
        case .invalidMetadataSize(let size):
            AgentLeaseFailure(
                kind: .lockIO,
                operation: "writeMetadata",
                message: "metadata size \(size) exceeds 4096 bytes"
            )
        case .metadataRequiresExclusive(let resource):
            AgentLeaseFailure(
                kind: .lockIO,
                operation: "writeMetadata",
                resource: resource,
                message: "shared leases cannot mutate common lock metadata"
            )
        case .released(let resource):
            AgentLeaseFailure(
                kind: .internal,
                operation: "lockDescriptor",
                resource: resource,
                message: "lock descriptor has already been released"
            )
        case .systemCall(let operation, let resource, let errorNumber):
            AgentLeaseFailure(
                kind: errorNumber == EMFILE || errorNumber == ENFILE ? .resourceLimit : .lockIO,
                operation: operation,
                errorNumber: errorNumber,
                resource: resource,
                message: AgentLeaseFailure.systemMessage(for: errorNumber)
            )
        case .unsafeFile(let resource, let reason):
            AgentLeaseFailure(
                kind: .unsafeState,
                operation: "validateLockFile",
                resource: resource,
                message: reason
            )
        }
    }
}

public enum BoundedMetadataRead: Equatable, Sendable {
    case absent
    case data(Data)
    case oversized
    case unreadable(AgentLeaseFailure)
}

public final class FileLock {
    public static let maximumMetadataBytes = 4_096
    public static let minimumOwnedDescriptor: Int32 = 64

    public let mode: LeaseMode
    public let persistentPath: String
    public let resource: ResourceName

    private var acquired = false
    private var descriptor: Int32
    private let metadataWriteFailure: FileLockError?

    public convenience init(
        resource: ResourceName,
        mode: LeaseMode = .exclusive,
        paths: AgentLeasePaths
    ) throws {
        try self.init(
            resource: resource,
            mode: mode,
            paths: paths,
            metadataWriteFailure: nil
        )
    }

    init(
        resource: ResourceName,
        mode: LeaseMode,
        paths: AgentLeasePaths,
        metadataWriteFailure: FileLockError?
    ) throws {
        self.resource = resource
        self.mode = mode
        persistentPath = paths.rootPath + "/locks/" + resource.lockFileName
        self.metadataWriteFailure = metadataWriteFailure
        descriptor = try Self.openPersistentLockFile(resource: resource, paths: paths)
    }

    deinit {
        release()
    }

    public var inheritedDescriptor: Int32? {
        acquired && descriptor >= 0 ? descriptor : nil
    }

    public var isAcquired: Bool {
        acquired && descriptor >= 0
    }

    @discardableResult
    public func tryAcquire() throws -> Bool {
        guard descriptor >= 0 else {
            throw FileLockError.released(resource.value)
        }
        guard !acquired else {
            throw FileLockError.alreadyAcquired(resource.value)
        }

        let operation = mode == .exclusive ? LOCK_EX : LOCK_SH
        while flock(descriptor, operation | LOCK_NB) != 0 {
            let lockError = errno
            if lockError == EINTR {
                continue
            }
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return false
            }
            throw FileLockError.systemCall(
                operation: "flock",
                resource: resource.value,
                errorNumber: lockError
            )
        }

        let originalDescriptor = descriptor
        let ownedDescriptor = Darwin.fcntl(
            originalDescriptor,
            F_DUPFD_CLOEXEC,
            Self.minimumOwnedDescriptor
        )
        guard ownedDescriptor >= Self.minimumOwnedDescriptor else {
            let duplicationError = errno
            descriptor = -1
            _ = Darwin.close(originalDescriptor)
            throw FileLockError.systemCall(
                operation: "fcntl(F_DUPFD_CLOEXEC)",
                resource: resource.value,
                errorNumber: duplicationError
            )
        }

        descriptor = ownedDescriptor
        acquired = true
        _ = Darwin.close(originalDescriptor)
        return true
    }

    public func clearCloseOnExec() throws {
        let ownedDescriptor = try requireAcquiredDescriptor()
        let flags = Darwin.fcntl(ownedDescriptor, F_GETFD)
        guard flags >= 0 else {
            throw FileLockError.systemCall(
                operation: "fcntl(F_GETFD)",
                resource: resource.value,
                errorNumber: errno
            )
        }
        guard Darwin.fcntl(ownedDescriptor, F_SETFD, flags & ~FD_CLOEXEC) == 0 else {
            throw FileLockError.systemCall(
                operation: "fcntl(F_SETFD)",
                resource: resource.value,
                errorNumber: errno
            )
        }
    }

    public func readMetadata() -> BoundedMetadataRead {
        guard descriptor >= 0 else {
            return .unreadable(FileLockError.released(resource.value).failure)
        }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            return .unreadable(
                FileLockError.systemCall(
                    operation: "fstat",
                    resource: resource.value,
                    errorNumber: errno
                ).failure
            )
        }
        guard status.st_size > 0 else { return .absent }
        guard status.st_size <= Self.maximumMetadataBytes else { return .oversized }

        let size = Int(status.st_size)
        var bytes = [UInt8](repeating: 0, count: size)
        var offset = 0
        while offset < size {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    size - offset,
                    off_t(offset)
                )
            }
            if result > 0 {
                offset += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                return .unreadable(
                    FileLockError.systemCall(
                        operation: "pread",
                        resource: resource.value,
                        errorNumber: result == 0 ? EIO : errno
                    ).failure
                )
            }
        }
        return .data(Data(bytes))
    }

    public func release() {
        guard descriptor >= 0 else { return }
        let descriptorToClose = descriptor
        descriptor = -1
        acquired = false
        _ = Darwin.close(descriptorToClose)
    }

    public func writeMetadata(_ data: Data) throws {
        guard mode == .exclusive else {
            throw FileLockError.metadataRequiresExclusive(resource.value)
        }
        if let metadataWriteFailure {
            throw metadataWriteFailure
        }
        guard data.count <= Self.maximumMetadataBytes else {
            throw FileLockError.invalidMetadataSize(data.count)
        }
        let ownedDescriptor = try requireAcquiredDescriptor()
        guard Darwin.ftruncate(ownedDescriptor, 0) == 0 else {
            throw FileLockError.systemCall(
                operation: "ftruncate",
                resource: resource.value,
                errorNumber: errno
            )
        }

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.pwrite(
                    ownedDescriptor,
                    baseAddress.advanced(by: written),
                    buffer.count - written,
                    off_t(written)
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw FileLockError.systemCall(
                        operation: "pwrite",
                        resource: resource.value,
                        errorNumber: result == 0 ? EIO : errno
                    )
                }
            }
        }
    }

    private func requireAcquiredDescriptor() throws -> Int32 {
        guard let inheritedDescriptor else {
            throw FileLockError.released(resource.value)
        }
        return inheritedDescriptor
    }

    private static func openPersistentLockFile(
        resource: ResourceName,
        paths: AgentLeasePaths
    ) throws -> Int32 {
        let fileName = resource.lockFileName
        var created = false
        var descriptor = fileName.withCString { pointer in
            Darwin.openat(
                paths.locksDirectoryDescriptor,
                pointer,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        if descriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            descriptor = fileName.withCString { pointer in
                Darwin.openat(
                    paths.locksDirectoryDescriptor,
                    pointer,
                    O_RDWR | O_NOFOLLOW | O_CLOEXEC
                )
            }
        }
        guard descriptor >= 0 else {
            throw FileLockError.systemCall(
                operation: "openat",
                resource: resource.value,
                errorNumber: errno
            )
        }

        do {
            if created, Darwin.fchmod(descriptor, 0o600) != 0 {
                throw FileLockError.systemCall(
                    operation: "fchmod",
                    resource: resource.value,
                    errorNumber: errno
                )
            }
            try validate(descriptor: descriptor, resource: resource)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func validate(descriptor: Int32, resource: ResourceName) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw FileLockError.systemCall(
                operation: "fstat",
                resource: resource.value,
                errorNumber: errno
            )
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw FileLockError.unsafeFile(
                resource: resource.value,
                reason: "lock path is not a regular file"
            )
        }
        guard status.st_uid == geteuid() else {
            throw FileLockError.unsafeFile(
                resource: resource.value,
                reason: "lock file is not owned by the effective user"
            )
        }
        guard status.st_nlink == 1 else {
            throw FileLockError.unsafeFile(
                resource: resource.value,
                reason: "lock file must have exactly one hard link"
            )
        }
        guard status.st_mode & 0o777 == 0o600 else {
            throw FileLockError.unsafeFile(
                resource: resource.value,
                reason: "lock file mode is not 0600"
            )
        }
    }
}
