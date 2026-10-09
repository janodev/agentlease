import Darwin
import Foundation
import Synchronization

/// Internal registry coordination is never part of the inherited resource manifest.
public final class RegistryClaim: Sendable {
    private let descriptor: Mutex<Int32>

    init(descriptor: Int32) {
        self.descriptor = Mutex(descriptor)
    }

    deinit { release() }

    public func release() {
        descriptor.withLock { descriptor in
            guard descriptor >= 0 else { return }
            _ = Darwin.close(descriptor)
            descriptor = -1
        }
    }
}

public enum RegistryGate {
    public static let fileName = ".registry.lock"

    /// Synchronous inspection/publication callers have a bounded admission wait.
    /// Async acquisition callers use the cancellation-aware overload below.
    public static func shared(paths: AgentLeasePaths) throws -> RegistryClaim {
        let started = DispatchTime.now().uptimeNanoseconds
        repeat {
            if let claim = try acquire(paths: paths, exclusive: false, nonblocking: true) {
                return claim
            }
            if DispatchTime.now().uptimeNanoseconds - started >= 1_000_000_000 {
                throw failure("flockRegistry", EWOULDBLOCK)
            }
            _ = usleep(25_000)
        } while true
    }

    public static func shared(
        paths: AgentLeasePaths,
        waitSeconds: Double?
    ) async throws -> RegistryClaim {
        if let waitSeconds, !waitSeconds.isFinite || waitSeconds < 0 {
            throw LeaseSetError.invalidWaitSeconds(waitSeconds)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        var attempts = 0
        while true {
            try Task.checkCancellation()
            if attempts > 0, let waitSeconds,
               Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000 >= waitSeconds {
                throw LeaseSetError.timedOut("registry")
            }
            attempts += 1
            if let claim = try acquire(paths: paths, exclusive: false, nonblocking: true) {
                do {
                    try Task.checkCancellation()
                    return claim
                } catch {
                    claim.release()
                    throw error
                }
            }
            let delay: Double
            if let waitSeconds {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
                let remaining = waitSeconds - elapsed
                guard remaining > 0 else { throw LeaseSetError.timedOut("registry") }
                delay = min(0.025, remaining)
            } else {
                delay = 0.025
            }
            try await Task.sleep(for: .seconds(delay))
        }
    }

    static func exclusive(paths: AgentLeasePaths) throws -> RegistryClaim? {
        try acquire(paths: paths, exclusive: true, nonblocking: true)
    }

    private static func acquire(
        paths: AgentLeasePaths,
        exclusive: Bool,
        nonblocking: Bool
    ) throws -> RegistryClaim? {
        var created = false
        var descriptor = openat(
            paths.rootDirectoryDescriptor, fileName,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600
        )
        if descriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            descriptor = openat(
                paths.rootDirectoryDescriptor, fileName,
                O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { throw failure("openRegistry", errno) }
        var keep = false
        defer { if !keep { _ = Darwin.close(descriptor) } }
        if created, fchmod(descriptor, 0o600) != 0 { throw failure("chmodRegistry", errno) }
        try SafeStateFile.validate(descriptor, directory: paths.rootDirectoryDescriptor, name: fileName)
        let operation = (exclusive ? LOCK_EX : LOCK_SH) | (nonblocking ? LOCK_NB : 0)
        while flock(descriptor, operation) != 0 {
            let code = errno
            if code == EINTR { continue }
            if nonblocking, code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw failure("flockRegistry", code)
        }
        try SafeStateFile.validate(descriptor, directory: paths.rootDirectoryDescriptor, name: fileName)
        keep = true
        return RegistryClaim(descriptor: descriptor)
    }

    private static func failure(_ operation: String, _ code: Int32) -> AgentLeaseFailure {
        AgentLeaseFailure(kind: .stateIO, operation: operation, errorNumber: code,
                          message: AgentLeaseFailure.systemMessage(for: code))
    }
}

/// Descriptor-relative identity checks are repeated immediately before unlinking.
enum SafeStateFile {
    static func validate(_ descriptor: Int32, directory: Int32, name: String) throws {
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw AgentLeaseFailure(kind: .stateIO, operation: "statStateFile", errorNumber: errno,
                                    message: "could not inspect state file")
        }
        guard opened.st_mode & S_IFMT == S_IFREG,
              named.st_mode & S_IFMT == S_IFREG,
              opened.st_uid == geteuid(), named.st_uid == geteuid(),
              opened.st_nlink == 1, named.st_nlink == 1,
              opened.st_mode & 0o777 == 0o600, named.st_mode & 0o777 == 0o600,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
            throw AgentLeaseFailure(kind: .unsafeState, operation: "validateStateFile",
                                    message: "unsafe state file or changed inode: \(name)")
        }
    }
}
