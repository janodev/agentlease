import AgentLeaseCore
import Darwin
import Foundation

@main
enum AgentLeaseSpikeHelper {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("spike helper: \(error)\n".utf8))
            Darwin.exit(70)
        }
    }

    private static func run(arguments: [String]) async throws {
        guard let command = arguments.first else {
            throw HelperError.missingCommand
        }

        switch command {
        case "check-basics":
            checkBasics()
        case "check-descriptor":
            let descriptor = try descriptor(from: arguments, at: 1)
            let flags = fcntl(descriptor, F_GETFD)
            guard flags >= 0, flags & FD_CLOEXEC == 0 else {
                Darwin.exit(1)
            }
            Darwin.exit(0)
        case "coordinate-inherited-lock":
            guard arguments.count == 3 else {
                throw HelperError.invalidArguments
            }
            try await coordinateInheritedLock(
                lockPath: arguments[1],
                markerPath: arguments[2]
            )
        case "hold-descriptor":
            let descriptor = try descriptor(from: arguments, at: 1)
            guard fcntl(descriptor, F_GETFD) >= 0 else {
                Darwin.exit(1)
            }
            waitForever()
        case "raise-interrupt":
            raise(SIGINT)
            Darwin.exit(99)
        case "wait-for-marker-and-exit":
            guard arguments.count == 3 else {
                throw HelperError.invalidArguments
            }
            try await waitForFile(at: arguments[1])
            Darwin.exit(try descriptor(from: arguments, at: 2))
        case "spawn-ignoring-grandchild":
            guard arguments.count == 2 else {
                throw HelperError.invalidArguments
            }
            try spawnIgnoringGrandchild(markerPath: arguments[1])
        case "write-arguments":
            guard arguments.count == 2 else {
                throw HelperError.invalidArguments
            }
            let data = try JSONEncoder().encode(CommandLine.arguments)
            try data.write(to: URL(fileURLWithPath: arguments[1]))
        case "hold-ignoring-signals":
            ignoreTerminationSignals()
            waitForever()
        case "hold-lease":
            try await holdLease(arguments: Array(arguments.dropFirst()))
        case "hold-lease-after-start":
            try await holdLease(arguments: Array(arguments.dropFirst()), waitsForStart: true)
        case "hold-inherited-locks":
            try holdInheritedLocks(arguments: Array(arguments.dropFirst()))
        case "probe-lease":
            try await probeLease(arguments: Array(arguments.dropFirst()))
        case "prepare-state":
            try prepareState(arguments: Array(arguments.dropFirst()), restrictiveUmask: false)
        case "prepare-state-restrictive":
            try prepareState(arguments: Array(arguments.dropFirst()), restrictiveUmask: true)
        case "exit":
            let code = try descriptor(from: arguments, at: 1)
            Darwin.exit(code)
        default:
            throw HelperError.invalidCommand(command)
        }
    }

    private static func checkBasics() {
        guard getsid(0) == getpid(), getpgrp() == getpid() else {
            Darwin.exit(1)
        }
        var byte: UInt8 = 0
        let count = Darwin.read(STDIN_FILENO, &byte, 1)
        Darwin.exit(count == 0 ? 0 : 2)
    }

    private static func coordinateInheritedLock(
        lockPath: String,
        markerPath: String
    ) async throws {
        let openedDescriptor = Darwin.open(
            lockPath,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard openedDescriptor >= 0 else {
            throw HelperError.systemCall("open", errno)
        }
        guard flock(openedDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = Darwin.close(openedDescriptor)
            throw HelperError.systemCall("flock", lockError)
        }
        let inheritedDescriptor = fcntl(openedDescriptor, F_DUPFD_CLOEXEC, 64)
        guard inheritedDescriptor >= 64 else {
            let duplicateError = errno
            _ = Darwin.close(openedDescriptor)
            throw HelperError.systemCall("fcntl", duplicateError)
        }
        _ = Darwin.close(openedDescriptor)

        defer { _ = Darwin.close(inheritedDescriptor) }
        let executablePath = CommandLine.arguments[0]
        _ = try await SupervisedSubprocess.run(
            executablePath: executablePath,
            arguments: [
                executablePath,
                "hold-descriptor",
                String(inheritedDescriptor),
            ],
            inheritedDescriptors: [inheritedDescriptor]
        ) { childPID in
            try "\(childPID)\n".write(
                toFile: markerPath,
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private static func spawnIgnoringGrandchild(markerPath: String) throws {
        ignoreTerminationSignals()

        let executablePath = CommandLine.arguments[0]
        let values = [executablePath, "hold-ignoring-signals"]
        let storage = values.map { strdup($0) }
        defer {
            for pointer in storage {
                free(pointer)
            }
        }
        var arguments = storage + [nil]
        var processIdentifier: pid_t = 0
        let result = executablePath.withCString { executable in
            arguments.withUnsafeMutableBufferPointer { arguments in
                posix_spawn(
                    &processIdentifier,
                    executable,
                    nil,
                    nil,
                    arguments.baseAddress,
                    environ
                )
            }
        }
        guard result == 0 else {
            throw HelperError.systemCall("posix_spawn", result)
        }
        try "\(processIdentifier)\n".write(
            toFile: markerPath,
            atomically: true,
            encoding: .utf8
        )
        waitForever()
    }

    private static func descriptor(from arguments: [String], at index: Int) throws -> Int32 {
        guard arguments.indices.contains(index), let value = Int32(arguments[index]) else {
            throw HelperError.invalidArguments
        }
        return value
    }

    private static func ignoreTerminationSignals() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
    }

    private static func holdLease(
        arguments: [String],
        waitsForStart: Bool = false
    ) async throws {
        let minimumArgumentCount = waitsForStart ? 5 : 4
        guard arguments.count >= minimumArgumentCount else {
            throw HelperError.invalidArguments
        }
        let homePath = arguments[0]
        let startPath = waitsForStart ? arguments[1] : nil
        let readyIndex = waitsForStart ? 2 : 1
        let readyPath = arguments[readyIndex]
        let releasePath = arguments[readyIndex + 1]
        let resourceValues = Array(arguments.dropFirst(readyIndex + 2))

        if let startPath {
            try await waitForFile(at: startPath)
        }
        let paths = try AgentLeasePaths.open(selectedRoot: homePath)
        let resources = try ResourceSet(resourceValues)
        let lease = try await LeaseSet.acquire(
            resources,
            paths: paths,
            waitSeconds: 5,
            initialMetadata: { resource in
                LockMetadata(
                    resourceName: resource.value,
                    runID: "spike-helper",
                    coordinatorPID: getpid(),
                    childPID: nil,
                    mode: .run,
                    state: .acquiring,
                    label: "test helper",
                    bead: nil,
                    acquiredAt: RunRecord.timestamp()
                )
            }
        )
        try "ready\n".write(toFile: readyPath, atomically: true, encoding: .utf8)
        try await waitForFile(at: releasePath)
        lease.release()
    }

    private static func holdInheritedLocks(arguments: [String]) throws {
        guard arguments.count == 1 else {
            throw HelperError.invalidArguments
        }
        var inheritedCount = 0
        for descriptor in FileLock.minimumOwnedDescriptor..<256 {
            if fcntl(descriptor, F_GETFD) >= 0 {
                inheritedCount += 1
            }
        }
        guard inheritedCount > 0 else {
            Darwin.exit(2)
        }
        try "\(getpid())\n".write(
            toFile: arguments[0],
            atomically: true,
            encoding: .utf8
        )
        waitForever()
    }

    private static func prepareState(arguments: [String], restrictiveUmask: Bool) throws {
        guard arguments.count == 1 else {
            throw HelperError.invalidArguments
        }
        if restrictiveUmask {
            _ = umask(0o777)
        }
        _ = try AgentLeasePaths.open(selectedRoot: arguments[0])
    }

    private static func probeLease(arguments: [String]) async throws {
        guard arguments.count >= 2 else {
            throw HelperError.invalidArguments
        }
        let paths = try AgentLeasePaths.open(selectedRoot: arguments[0])
        let resources = try ResourceSet(Array(arguments.dropFirst()))
        do {
            let lease = try await LeaseSet.acquire(
                resources,
                paths: paths,
                waitSeconds: 0,
                initialMetadata: { resource in
                    LockMetadata(
                        resourceName: resource.value,
                        runID: "probe-helper",
                        coordinatorPID: getpid(),
                        childPID: nil,
                        mode: .run,
                        state: .acquiring,
                        label: nil,
                        bead: nil,
                        acquiredAt: RunRecord.timestamp()
                    )
                }
            )
            lease.release()
        } catch is LeaseSetError {
            Darwin.exit(75)
        }
    }

    private static func waitForFile(at path: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if access(path, F_OK) == 0 {
                return
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        throw HelperError.markerTimeout(path)
    }

    private static func waitForever() -> Never {
        while true {
            _ = pause()
        }
    }
}

private enum HelperError: Error {
    case invalidArguments
    case invalidCommand(String)
    case missingCommand
    case markerTimeout(String)
    case systemCall(String, Int32)
}
