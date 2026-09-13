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
        case "spawn-ignoring-grandchild":
            guard arguments.count == 2 else {
                throw HelperError.invalidArguments
            }
            try spawnIgnoringGrandchild(markerPath: arguments[1])
        case "hold-ignoring-signals":
            ignoreTerminationSignals()
            waitForever()
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["hold-ignoring-signals"]
        try process.run()
        try "\(process.processIdentifier)\n".write(
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
    case systemCall(String, Int32)
}
