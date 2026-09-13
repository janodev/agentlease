import Darwin
import Foundation

public enum LeaseAvailability: String, Codable, Sendable {
    case free
    case held
    case unknown
}

public enum MetadataStatus: String, Codable, Sendable {
    case absent
    case invalid
    case oversized
    case unreadable
    case valid
}

public struct StatusEntry: Codable, Equatable, Sendable {
    public let fileName: String
    public let digest: String?
    public let resource: String?
    public let availability: LeaseAvailability
    public let metadataStatus: MetadataStatus
    public let lastOwner: LockMetadata?
    public let error: AgentLeaseFailure?

    public init(
        fileName: String,
        digest: String?,
        resource: String?,
        availability: LeaseAvailability,
        metadataStatus: MetadataStatus,
        lastOwner: LockMetadata?,
        error: AgentLeaseFailure?
    ) {
        self.fileName = fileName
        self.digest = digest
        self.resource = resource
        self.availability = availability
        self.metadataStatus = metadataStatus
        self.lastOwner = lastOwner
        self.error = error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fileName, forKey: .fileName)
        try encodeNullable(digest, in: &container, forKey: .digest)
        try encodeNullable(resource, in: &container, forKey: .resource)
        try container.encode(availability, forKey: .availability)
        try container.encode(metadataStatus, forKey: .metadataStatus)
        try encodeNullable(lastOwner, in: &container, forKey: .lastOwner)
        try encodeNullable(error, in: &container, forKey: .error)
    }
}

public struct StatusReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let stateRoot: String
    public let entries: [StatusEntry]
    public let errors: [AgentLeaseFailure]

    public init(
        schemaVersion: Int = 1,
        stateRoot: String,
        entries: [StatusEntry],
        errors: [AgentLeaseFailure]
    ) {
        self.schemaVersion = schemaVersion
        self.stateRoot = stateRoot
        self.entries = entries
        self.errors = errors
    }
}

public struct StatusProbeResult: Sendable {
    public let report: StatusReport
    public let requiresFailureExit: Bool

    public init(report: StatusReport, requiresFailureExit: Bool) {
        self.report = report
        self.requiresFailureExit = requiresFailureExit
    }
}

public enum StatusProbe {
    public static func inspect(paths: AgentLeasePaths) -> StatusProbeResult {
        let enumeration = enumerate(paths: paths)
        var entries: [StatusEntry] = []
        var requiresFailureExit = !enumeration.errors.isEmpty
        for name in enumeration.names {
            guard let fileName = String(bytes: name, encoding: .utf8),
                  let digest = lockDigest(from: name) else {
                requiresFailureExit = true
                let displayName = String(decoding: name, as: UTF8.self)
                entries.append(
                    StatusEntry(
                        fileName: displayName,
                        digest: nil,
                        resource: nil,
                        availability: .unknown,
                        metadataStatus: .invalid,
                        lastOwner: nil,
                        error: AgentLeaseFailure(
                            kind: .unsafeState,
                            operation: "validateStatusEntry",
                            message: "unexpected lock directory entry: \(displayName)"
                        )
                    )
                )
                continue
            }

            let result = inspect(fileName: fileName, digest: digest, paths: paths)
            entries.append(result.entry)
            requiresFailureExit = requiresFailureExit || result.requiresFailureExit
        }
        return StatusProbeResult(
            report: StatusReport(
                stateRoot: paths.rootPath,
                entries: entries,
                errors: enumeration.errors
            ),
            requiresFailureExit: requiresFailureExit
        )
    }

    private struct EntryInspection {
        let entry: StatusEntry
        let requiresFailureExit: Bool
    }

    private struct EnumerationResult {
        let errors: [AgentLeaseFailure]
        let names: [[UInt8]]
    }

    private enum MetadataInspection {
        case absent
        case invalid(AgentLeaseFailure)
        case oversized(AgentLeaseFailure)
        case unreadable(AgentLeaseFailure)
        case valid(resource: String, metadata: LockMetadata)
    }

    private static func enumerate(paths: AgentLeasePaths) -> EnumerationResult {
        let descriptor = ".".withCString { pointer in
            Darwin.openat(
                paths.locksDirectoryDescriptor,
                pointer,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            return EnumerationResult(
                errors: [systemFailure(operation: "openatLocks", errorNumber: errno)],
                names: []
            )
        }
        guard let directory = fdopendir(descriptor) else {
            let errorNumber = errno
            _ = Darwin.close(descriptor)
            return EnumerationResult(
                errors: [systemFailure(operation: "fdopendir", errorNumber: errorNumber)],
                names: []
            )
        }
        defer { closedir(directory) }

        var errors: [AgentLeaseFailure] = []
        var names: [[UInt8]] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 {
                    errors.append(systemFailure(operation: "readdir", errorNumber: errno))
                }
                break
            }
            let bytes = withUnsafeBytes(of: entry.pointee.d_name) { rawBuffer in
                let values = rawBuffer.map { UInt8($0) }
                let terminator = values.firstIndex(of: 0) ?? values.endIndex
                return Array(values[..<terminator])
            }
            if bytes == [0x2e] || bytes == [0x2e, 0x2e] {
                continue
            }
            names.append(bytes)
        }
        names.sort { $0.lexicographicallyPrecedes($1) }
        return EnumerationResult(errors: errors, names: names)
    }

    private static func inspect(
        fileName: String,
        digest: String,
        paths: AgentLeasePaths
    ) -> EntryInspection {
        let descriptor = fileName.withCString { pointer in
            Darwin.openat(
                paths.locksDirectoryDescriptor,
                pointer,
                O_RDWR | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            return failedEntry(
                fileName: fileName,
                digest: digest,
                failure: systemFailure(
                    operation: "openatStatusEntry",
                    errorNumber: errno
                )
            )
        }
        defer { _ = Darwin.close(descriptor) }

        if let failure = validate(descriptor: descriptor, fileName: fileName) {
            return failedEntry(fileName: fileName, digest: digest, failure: failure)
        }

        let availability: LeaseAvailability
        var probeFailure: AgentLeaseFailure?
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                availability = .free
                break
            }
            let errorNumber = errno
            if errorNumber == EINTR {
                continue
            }
            if errorNumber == EWOULDBLOCK || errorNumber == EAGAIN {
                availability = .held
            } else {
                availability = .unknown
                probeFailure = systemFailure(
                    operation: "flockStatusProbe",
                    errorNumber: errorNumber
                )
            }
            break
        }

        let metadata = inspectMetadata(descriptor: descriptor, digest: digest)
        let metadataFields: (
            status: MetadataStatus,
            resource: String?,
            owner: LockMetadata?,
            error: AgentLeaseFailure?
        ) = switch metadata {
        case .absent:
            (.absent, nil, nil, nil)
        case .invalid(let failure):
            (.invalid, nil, nil, failure)
        case .oversized(let failure):
            (.oversized, nil, nil, failure)
        case .unreadable(let failure):
            (.unreadable, nil, nil, failure)
        case .valid(let resource, let owner):
            (.valid, resource, owner, nil)
        }
        return EntryInspection(
            entry: StatusEntry(
                fileName: fileName,
                digest: digest,
                resource: metadataFields.resource,
                availability: availability,
                metadataStatus: metadataFields.status,
                lastOwner: metadataFields.owner,
                error: probeFailure ?? metadataFields.error
            ),
            requiresFailureExit: probeFailure != nil
        )
    }

    private static func inspectMetadata(
        descriptor: Int32,
        digest: String
    ) -> MetadataInspection {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            return .unreadable(systemFailure(operation: "fstatMetadata", errorNumber: errno))
        }
        guard status.st_size > 0 else { return .absent }
        guard status.st_size <= FileLock.maximumMetadataBytes else {
            return .oversized(
                AgentLeaseFailure(
                    kind: .lockIO,
                    operation: "readMetadata",
                    message: "lock metadata exceeds 4096 bytes"
                )
            )
        }

        let size = Int(status.st_size)
        var bytes = [UInt8](repeating: 0, count: size)
        var offset = 0
        while offset < size {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    size - offset,
                    off_t(offset)
                )
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return .unreadable(
                    systemFailure(
                        operation: "preadMetadata",
                        errorNumber: count == 0 ? EIO : errno
                    )
                )
            }
        }

        let metadata: LockMetadata
        do {
            metadata = try JSONDecoder().decode(LockMetadata.self, from: Data(bytes))
        } catch {
            return .invalid(
                AgentLeaseFailure(
                    kind: .lockIO,
                    operation: "decodeMetadata",
                    message: String(describing: error)
                )
            )
        }
        do {
            let resource = try ResourceName(metadata.resourceName)
            try TextFieldValidator.validate(metadata.label, field: "label")
            try TextFieldValidator.validate(metadata.bead, field: "bead")
            guard metadata.schemaVersion == 1,
                  resource.lockDigest == digest,
                  UUID(uuidString: metadata.runID) != nil,
                  metadata.coordinatorPID > 0,
                  metadata.childPID.map({ $0 > 0 }) ?? true,
                  isSafeMetadataText(metadata.acquiredAt) else {
                throw StatusMetadataError.invalidFields
            }
            return .valid(resource: resource.value, metadata: metadata)
        } catch {
            return .invalid(
                AgentLeaseFailure(
                    kind: .lockIO,
                    operation: "validateMetadata",
                    message: "lock metadata does not match its schema or filename"
                )
            )
        }
    }

    private static func failedEntry(
        fileName: String,
        digest: String,
        failure: AgentLeaseFailure
    ) -> EntryInspection {
        EntryInspection(
            entry: StatusEntry(
                fileName: fileName,
                digest: digest,
                resource: nil,
                availability: .unknown,
                metadataStatus: .unreadable,
                lastOwner: nil,
                error: failure
            ),
            requiresFailureExit: true
        )
    }

    private static func isSafeMetadataText(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 512
            && AgentLeaseFailure.sanitized(value) == value
    }

    private static func validate(
        descriptor: Int32,
        fileName: String
    ) -> AgentLeaseFailure? {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            return systemFailure(operation: "fstatStatusEntry", errorNumber: errno)
        }
        let reason: String?
        if status.st_mode & S_IFMT != S_IFREG {
            reason = "lock entry is not a regular file"
        } else if status.st_uid != geteuid() {
            reason = "lock entry is not owned by the effective user"
        } else if status.st_nlink != 1 {
            reason = "lock entry must have exactly one hard link"
        } else if status.st_mode & 0o777 != 0o600 {
            reason = "lock entry mode is not 0600"
        } else {
            reason = nil
        }
        return reason.map {
            AgentLeaseFailure(
                kind: .unsafeState,
                operation: "validateStatusEntry",
                message: "\(fileName): \($0)"
            )
        }
    }

    private static func lockDigest(from name: [UInt8]) -> String? {
        guard name.count == 69,
              Array(name.suffix(5)) == Array(".lock".utf8),
              name.prefix(64).allSatisfy({
                  (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
              }) else {
            return nil
        }
        return String(decoding: name.prefix(64), as: UTF8.self)
    }

    private static func systemFailure(
        operation: String,
        errorNumber: Int32
    ) -> AgentLeaseFailure {
        AgentLeaseFailure(
            kind: .lockIO,
            operation: operation,
            errorNumber: errorNumber,
            message: AgentLeaseFailure.systemMessage(for: errorNumber)
        )
    }
}

private enum StatusMetadataError: Error {
    case invalidFields
}

private func encodeNullable<T: Encodable, Key: CodingKey>(
    _ value: T?,
    in container: inout KeyedEncodingContainer<Key>,
    forKey key: Key
) throws {
    if let value {
        try container.encode(value, forKey: key)
    } else {
        try container.encodeNil(forKey: key)
    }
}
