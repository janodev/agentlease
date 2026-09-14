import Darwin
import Foundation

public enum InheritedExclusiveLeaseGuardError: Error, Equatable, Sendable {
    case descriptorIdentityMismatch
    case leaseMismatch
    case lockUnavailable(Int32)

    public var failure: AgentLeaseFailure {
        switch self {
        case .descriptorIdentityMismatch:
            AgentLeaseFailure(
                kind: .unsafeState,
                operation: "verifyInheritedExclusiveLease",
                message: "inherited descriptor does not name its declared safe lock file"
            )
        case .leaseMismatch:
            AgentLeaseFailure(
                kind: .environment,
                operation: "verifyInheritedExclusiveLease",
                message: "expected exactly one matching exclusive lease"
            )
        case .lockUnavailable(let errorNumber):
            AgentLeaseFailure(
                kind: .lockIO,
                operation: "flock",
                errorNumber: errorNumber,
                message: "could not establish the inherited exclusive lease"
            )
        }
    }
}

/// Establishes one expected exclusive lease on an inherited open-file
/// description after validating its complete environment and inode identity.
///
/// The caller must retain another reference to the same open-file description.
/// Closing this process's descriptor then leaves the established lock with the
/// caller. This is intentionally single-resource: a multi-resource guard could
/// retain partially established locks after a later validation failure.
public enum InheritedExclusiveLeaseGuard {
    public static func establish(
        resource expectedResource: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let resource = try ResourceName(expectedResource)
        guard environment[ChildEnvironment.heldResourcesKey] == resource.value,
              let encoded = environment[InheritedLeaseManifest.environmentKey]
        else {
            throw InheritedExclusiveLeaseGuardError.leaseMismatch
        }
        let manifest = try InheritedLeaseManifest.decodeEnvironmentValue(encoded)
        guard manifest.leases.count == 1,
              let lease = manifest.leases.first,
              lease.resource == resource.value,
              lease.mode == .exclusive else {
            throw InheritedExclusiveLeaseGuardError.leaseMismatch
        }

        let paths = try AgentLeasePaths.open(environment: environment)
        let expectedPath = paths.rootPath + "/locks/" + resource.lockFileName
        guard lease.path == expectedPath else {
            throw InheritedExclusiveLeaseGuardError.descriptorIdentityMismatch
        }
        try validateDescriptor(lease.descriptor, path: expectedPath)

        while flock(lease.descriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            if lockError == EINTR { continue }
            throw InheritedExclusiveLeaseGuardError.lockUnavailable(lockError)
        }
    }

    private static func validateDescriptor(
        _ descriptor: Int32,
        path: String
    ) throws {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              lstat(path, &pathStatus) == 0,
              (descriptorStatus.st_mode & S_IFMT) == S_IFREG,
              (pathStatus.st_mode & S_IFMT) == S_IFREG,
              descriptorStatus.st_uid == geteuid(),
              pathStatus.st_uid == geteuid(),
              descriptorStatus.st_nlink == 1,
              pathStatus.st_nlink == 1,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino,
              descriptorStatus.st_mode & 0o777 == 0o600,
              pathStatus.st_mode & 0o777 == 0o600 else {
            throw InheritedExclusiveLeaseGuardError.descriptorIdentityMismatch
        }
    }
}
