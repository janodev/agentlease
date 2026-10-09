import Darwin
import Foundation

public struct CleanupOptions: Sendable {
    public let execute: Bool
    public let olderThanDays: Double
    public let protectedLockDigests: Set<String>
    public let protectedLockPaths: Set<String>
    public let protectedRunIDs: Set<String>

    public init(
        execute: Bool = false,
        olderThanDays: Double = 7,
        protectedLockDigests: Set<String> = [],
        protectedLockPaths: Set<String> = [],
        protectedRunIDs: Set<String> = []
    ) {
        self.execute = execute
        self.olderThanDays = olderThanDays
        self.protectedLockDigests = protectedLockDigests
        self.protectedLockPaths = protectedLockPaths
        self.protectedRunIDs = protectedRunIDs
    }
}

public struct CleanupEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case resourceLock, runRecord }
    public enum Action: String, Codable, Sendable { case kept, wouldRemove, removed, failed }
    public let kind: Kind
    public let fileName: String
    public let action: Action
    public let reason: String
}

public struct CleanupReport: Codable, Sendable {
    public let schemaVersion: Int
    public let stateRoot: String
    public let execute: Bool
    public var busy = false
    public var throttled = false
    public var entries: [CleanupEntry] = []
    public var errors: [AgentLeaseFailure] = []
    public var removedCount = 0
    public var eligibleCount = 0

    init(stateRoot: String, execute: Bool) {
        schemaVersion = 1
        self.stateRoot = stateRoot
        self.execute = execute
    }
}

/// Retirement is allowed only under the permanent registry's exclusive gate,
/// with an independently acquired kernel lock and unchanged safe pathname inode.
public enum LeaseCleanup {
    public static let automaticEnvironmentKey = "AGENTLEASE_AUTO_CLEANUP"
    public static let protectedDigestsEnvironmentKey = "AGENTLEASE_CLEANUP_KEEP_LOCK_DIGESTS"
    public static let automaticStampFileName = ".cleanup-last-run"
    public static let maximumProtectionCount = 1_024
    private static let maximumRecordBytes = 1_048_576

    public static func perform(
        paths: AgentLeasePaths,
        options: CleanupOptions = CleanupOptions(),
        now: Date = Date()
    ) throws -> CleanupReport {
        let protections = try validatedProtections(options, paths: paths)
        var report = CleanupReport(stateRoot: paths.rootPath, execute: options.execute)
        guard let claim = try RegistryGate.exclusive(paths: paths) else {
            report.busy = true
            return report
        }
        defer { claim.release() }
        collect(paths: paths, options: options, protections: protections, now: now, report: &report)
        return report
    }

    /// Opt-in is deliberate: an integration must first stop legacy acquisitions
    /// and supply any retained descriptor/replay references it still needs.
    public static func automatic(
        paths: AgentLeasePaths,
        environment: [String: String],
        now: Date = Date()
    ) throws -> CleanupReport? {
        guard environment[automaticEnvironmentKey] == "1" else { return nil }
        let encoded = environment[protectedDigestsEnvironmentKey] ?? ""
        guard encoded.utf8.count <= 131_072 else { throw invalid("protection environment is too large") }
        let values = encoded.isEmpty ? [] : encoded.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let options = CleanupOptions(execute: true, protectedLockDigests: Set(values))
        guard values.count <= maximumProtectionCount else { throw invalid("too many protected digests") }
        let protections = try validatedProtections(options, paths: paths)
        var report = CleanupReport(stateRoot: paths.rootPath, execute: true)
        guard let claim = try RegistryGate.exclusive(paths: paths) else {
            report.busy = true
            return report
        }
        defer { claim.release() }
        let descriptor = openat(paths.rootDirectoryDescriptor, automaticStampFileName,
                                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        let stamp: Int32
        if descriptor >= 0 {
            stamp = descriptor
            guard fchmod(stamp, 0o600) == 0 else {
                let code = errno
                _ = Darwin.close(stamp)
                throw system("chmodCleanupStamp", code)
            }
        } else if errno == EEXIST {
            stamp = openat(paths.rootDirectoryDescriptor, automaticStampFileName,
                           O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        } else {
            throw system("openCleanupStamp", errno)
        }
        guard stamp >= 0 else { throw system("openCleanupStamp", errno) }
        defer { _ = Darwin.close(stamp) }
        try SafeStateFile.validate(stamp, directory: paths.rootDirectoryDescriptor, name: automaticStampFileName)
        var status = stat()
        guard fstat(stamp, &status) == 0 else { throw system("statCleanupStamp", errno) }
        // A newly created empty stamp has no completed maintenance pass yet.
        if status.st_size > 0, now.timeIntervalSince1970 - modificationTime(status) < 86_400 {
            report.throttled = true
            return report
        }
        collect(paths: paths, options: options, protections: protections, now: now, report: &report)
        let marker = [UInt8(ascii: "1")]
        guard marker.withUnsafeBytes({ pwrite(stamp, $0.baseAddress, 1, 0) }) == 1 else {
            throw system("writeCleanupStamp", errno)
        }
        var times = [timespec(tv_sec: Int(now.timeIntervalSince1970), tv_nsec: 0),
                     timespec(tv_sec: Int(now.timeIntervalSince1970), tv_nsec: 0)]
        guard futimens(stamp, &times) == 0 else { throw system("touchCleanupStamp", errno) }
        return report
    }

    private static func collect(
        paths: AgentLeasePaths, options: CleanupOptions, protections: Set<String>,
        now: Date, report: inout CleanupReport
    ) {
        let cutoff = now.timeIntervalSince1970 - options.olderThanDays * 86_400
        // Probe records before retiring locks, while all referenced inodes remain available.
        for name in names(in: paths.runsDirectoryDescriptor, report: &report) {
            inspectRun(name, paths: paths, options: options, cutoff: cutoff, report: &report)
        }
        for name in names(in: paths.locksDirectoryDescriptor, report: &report) {
            inspectLock(name, paths: paths, options: options, protections: protections,
                        cutoff: cutoff, report: &report)
        }
    }

    private static func inspectLock(
        _ name: String, paths: AgentLeasePaths, options: CleanupOptions,
        protections: Set<String>, cutoff: TimeInterval, report: inout CleanupReport
    ) {
        let kind = CleanupEntry.Kind.resourceLock
        guard name.hasSuffix(".lock"), isDigest(String(name.dropLast(5))) else {
            fail(name, kind: kind, invalid("unexpected lock entry"), report: &report)
            return
        }
        if protections.contains(String(name.dropLast(5))) {
            keep(name, kind: kind, "protected", report: &report)
            return
        }
        withSafeFile(name, directory: paths.locksDirectoryDescriptor, kind: kind, report: &report) { descriptor, status, report in
            guard modificationTime(status) < cutoff else {
                keep(name, kind: kind, "recent", report: &report)
                return
            }
            guard tryLock(descriptor) else {
                keep(name, kind: kind, "heldOrUnprobeable", report: &report)
                return
            }
            retire(name, directory: paths.locksDirectoryDescriptor, descriptor: descriptor,
                   kind: kind, execute: options.execute, report: &report)
        }
    }

    private static func inspectRun(
        _ name: String, paths: AgentLeasePaths, options: CleanupOptions,
        cutoff: TimeInterval, report: inout CleanupReport
    ) {
        let kind = CleanupEntry.Kind.runRecord
        guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil else {
            fail(name, kind: kind, invalid("unexpected run entry"), report: &report)
            return
        }
        withSafeFile(name, directory: paths.runsDirectoryDescriptor, kind: kind, report: &report) { descriptor, status, report in
            do {
                guard status.st_size > 0, status.st_size <= maximumRecordBytes else {
                    throw invalid("invalid run record size")
                }
                var bytes = [UInt8](repeating: 0, count: Int(status.st_size))
                var offset = 0
                let size = bytes.count
                while offset < size {
                    let count = bytes.withUnsafeMutableBytes {
                        pread(descriptor, $0.baseAddress?.advanced(by: offset), size - offset, off_t(offset))
                    }
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw system("readCleanupRun", count == 0 ? EIO : errno) }
                    offset += count
                }
                let record = try JSONDecoder().decode(RunRecord.self, from: Data(bytes))
                let resources = try validatedRun(record, fileName: name)
                if options.protectedRunIDs.contains(record.runID) {
                    keep(name, kind: kind, "protected", report: &report)
                    return
                }
                guard let started = timestamp(record.startedAt) else { throw invalid("invalid run timestamps") }
                let last: Date
                if let finishedAt = record.finishedAt {
                    guard let finished = timestamp(finishedAt), finished >= started else {
                        throw invalid("invalid run timestamps")
                    }
                    last = finished
                } else {
                    last = started
                }
                guard max(modificationTime(status), last.timeIntervalSince1970) < cutoff else {
                    keep(name, kind: kind, "recent", report: &report)
                    return
                }
                if record.state == .acquiring,
                   kill(record.coordinatorPID, 0) == 0 || errno == EPERM {
                    keep(name, kind: kind, "liveAcquiringCoordinator", report: &report)
                    return
                }
                for resource in resources {
                    guard resourceIsFree(resource, paths: paths) else {
                        keep(name, kind: kind, "referencedResourceHeldOrUnsafe", report: &report)
                        return
                    }
                }
                retire(name, directory: paths.runsDirectoryDescriptor, descriptor: descriptor,
                       kind: kind, execute: options.execute, report: &report)
            } catch {
                fail(name, kind: kind, error, report: &report)
            }
        }
    }

    private static func validatedRun(_ record: RunRecord, fileName: String) throws -> [ResourceName] {
        guard (1...2).contains(record.schemaVersion), record.runID + ".json" == fileName,
              UUID(uuidString: record.runID) != nil, record.coordinatorPID > 0,
              record.childPID.map({ $0 > 0 }) ?? true else { throw invalid("invalid run record identity") }
        let resources = try ResourceSet(record.resources).resources
        guard record.resourceLeases.map(\.resource).sorted() == resources,
              Set(record.resourceLeases.map(\.resource)).count == resources.count else {
            throw invalid("invalid run resource envelope")
        }
        return resources
    }

    private static func resourceIsFree(_ resource: ResourceName, paths: AgentLeasePaths) -> Bool {
        let descriptor = openat(paths.locksDirectoryDescriptor, resource.lockFileName,
                                O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 { return errno == ENOENT }
        defer { _ = Darwin.close(descriptor) }
        do {
            try SafeStateFile.validate(descriptor, directory: paths.locksDirectoryDescriptor, name: resource.lockFileName)
            return tryLock(descriptor)
        } catch { return false }
    }

    private static func tryLock(_ descriptor: Int32) -> Bool {
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            return false
        }
        return true
    }

    private static func withSafeFile(
        _ name: String, directory: Int32, kind: CleanupEntry.Kind, report: inout CleanupReport,
        body: (Int32, stat, inout CleanupReport) -> Void
    ) {
        let descriptor = openat(directory, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            fail(name, kind: kind, system("openCleanupEntry", errno), report: &report)
            return
        }
        defer { _ = Darwin.close(descriptor) }
        do {
            try SafeStateFile.validate(descriptor, directory: directory, name: name)
            var status = stat()
            guard fstat(descriptor, &status) == 0 else { throw system("statCleanupEntry", errno) }
            body(descriptor, status, &report)
        } catch { fail(name, kind: kind, error, report: &report) }
    }

    private static func retire(
        _ name: String, directory: Int32, descriptor: Int32, kind: CleanupEntry.Kind,
        execute: Bool, report: inout CleanupReport
    ) {
        do {
            try SafeStateFile.validate(descriptor, directory: directory, name: name)
            if execute, unlinkat(directory, name, 0) != 0 { throw system("unlinkCleanupEntry", errno) }
            report.eligibleCount += 1
            if execute { report.removedCount += 1 }
            report.entries.append(CleanupEntry(kind: kind, fileName: name,
                                               action: execute ? .removed : .wouldRemove, reason: "oldAndKernelFree"))
        } catch { fail(name, kind: kind, error, report: &report) }
    }

    private static func names(in directory: Int32, report: inout CleanupReport) -> [String] {
        let descriptor = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { report.errors.append(system("openCleanupDirectory", errno)); return [] }
        guard let stream = fdopendir(descriptor) else {
            let code = errno
            _ = Darwin.close(descriptor)
            report.errors.append(system("readCleanupDirectory", code))
            return []
        }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { report.errors.append(system("readCleanupDirectory", errno)) }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if name != ".", name != ".." { result.append(name) }
        }
        return result.sorted()
    }

    private static func validatedProtections(_ options: CleanupOptions, paths: AgentLeasePaths) throws -> Set<String> {
        guard options.olderThanDays.isFinite, options.olderThanDays >= 0,
              options.protectedLockDigests.count + options.protectedLockPaths.count + options.protectedRunIDs.count <= maximumProtectionCount else {
            throw invalid("invalid retention age or too many protections")
        }
        var digests = options.protectedLockDigests
        guard digests.allSatisfy(isDigest), options.protectedRunIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw invalid("invalid protected digest or run ID")
        }
        for path in options.protectedLockPaths {
            let prefix = paths.rootPath + "/locks/"
            guard path.hasPrefix(prefix), path.hasSuffix(".lock") else { throw invalid("protected path must name a lock in this state root") }
            let digest = String(path.dropFirst(prefix.count).dropLast(5))
            guard isDigest(digest) else { throw invalid("invalid protected lock path") }
            digests.insert(digest)
        }
        return digests
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func timestamp(_ value: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
    private static func modificationTime(_ status: stat) -> TimeInterval {
        Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000
    }
    private static func keep(_ name: String, kind: CleanupEntry.Kind, _ reason: String, report: inout CleanupReport) {
        report.entries.append(CleanupEntry(kind: kind, fileName: name, action: .kept, reason: reason))
    }
    private static func fail(_ name: String, kind: CleanupEntry.Kind, _ error: any Error, report: inout CleanupReport) {
        let failure = (error as? AgentLeaseFailure) ?? invalid(String(describing: error))
        report.errors.append(failure)
        report.entries.append(CleanupEntry(kind: kind, fileName: name, action: .failed, reason: failure.message))
    }
    private static func invalid(_ message: String) -> AgentLeaseFailure {
        AgentLeaseFailure(kind: .unsafeState, operation: "validateCleanup", message: message)
    }
    private static func system(_ operation: String, _ code: Int32) -> AgentLeaseFailure {
        AgentLeaseFailure(kind: .stateIO, operation: operation, errorNumber: code,
                          message: AgentLeaseFailure.systemMessage(for: code))
    }
}
