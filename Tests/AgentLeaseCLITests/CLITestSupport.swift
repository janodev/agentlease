import AgentLeaseCore
import Darwin
import Foundation

enum CLITestError: Error, CustomStringConvertible {
    case binaryNotFound(String)
    case markerTimeout(String)
    case processExitedEarly(status: Int32, output: String)
    case processGroupTimeout(Int32)
    case processTimeout(Int32)
    case systemCall(operation: String, errorNumber: Int32)

    var description: String {
        switch self {
        case .binaryNotFound(let name):
            "built executable was not found: \(name)"
        case .markerTimeout(let path):
            "timed out waiting for marker: \(path)"
        case .processExitedEarly(let status, let output):
            "process exited early with \(status):\n\(output)"
        case .processGroupTimeout(let processGroup):
            "process group \(processGroup) did not exit"
        case .processTimeout(let processIdentifier):
            "process \(processIdentifier) did not exit"
        case .systemCall(let operation, let errorNumber):
            "\(operation) failed with errno \(errorNumber)"
        }
    }
}

struct CLIProcess {
    let process: Process
    let standardError: Pipe
    let standardOutput: Pipe

    func errorText() -> String {
        String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? "<non-UTF-8 stderr>"
    }

    func outputText() -> String {
        String(
            data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? "<non-UTF-8 stdout>"
    }
}

struct CLIFixture {
    let parent: URL
    let stateRoot: URL

    init() throws {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentlease-cli-tests-\(UUID().uuidString)")
        stateRoot = parent.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    }

    func agentLease(
        _ arguments: [String],
        environment additions: [String: String] = [:],
        standardError suppliedStandardError: Pipe? = nil,
        standardInput: Any? = nil
    ) throws -> CLIProcess {
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTLEASE_HOME"] = stateRoot.path
        for (key, value) in additions {
            environment[key] = value
        }
        return try launch(
            executable: builtExecutable(named: "agentlease"),
            arguments: arguments,
            environment: environment,
            standardError: suppliedStandardError,
            standardInput: standardInput
        )
    }

    func helper(_ arguments: [String]) throws -> CLIProcess {
        try launch(
            executable: builtExecutable(named: "agentlease-spike-helper"),
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            standardError: nil,
            standardInput: nil
        )
    }

    func lockPath(resource: String) throws -> URL {
        let name = try ResourceName(resource)
        return stateRoot.appendingPathComponent("locks/\(name.lockFileName)")
    }

    func readRecords() throws -> [RunRecord] {
        let runs = stateRoot.appendingPathComponent("runs")
        guard FileManager.default.fileExists(atPath: runs.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: runs,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.map {
            try JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: $0))
        }
    }

    func waitForRecord(
        coordinatorPID: Int32,
        state: RunState,
        process: CLIProcess? = nil,
        timeout: Duration = .seconds(5)
    ) async throws -> RunRecord {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let record = try? readRecords().first(where: {
                $0.coordinatorPID == coordinatorPID && $0.state == state
            }) {
                return record
            }
            if let process, !process.process.isRunning {
                throw CLITestError.processExitedEarly(
                    status: process.process.terminationStatus,
                    output: process.errorText() + process.outputText()
                )
            }
            try await clock.sleep(for: .milliseconds(10))
        }
        throw CLITestError.markerTimeout("run record state \(state.rawValue)")
    }

    func remove() {
        try? FileManager.default.removeItem(at: parent)
    }

    private func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardError suppliedStandardError: Pipe?,
        standardInput: Any?
    ) throws -> CLIProcess {
        let process = Process()
        let standardError = suppliedStandardError ?? Pipe()
        let standardOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardError = standardError
        process.standardOutput = standardOutput
        if let standardInput {
            process.standardInput = standardInput
        }
        try process.run()
        return CLIProcess(
            process: process,
            standardError: standardError,
            standardOutput: standardOutput
        )
    }
}

func builtExecutable(named name: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let conventional = packageRoot.appendingPathComponent(".build/debug/\(name)").path
    if access(conventional, X_OK) == 0 {
        return conventional
    }
    if let enumerator = FileManager.default.enumerator(
        at: packageRoot.appendingPathComponent(".build"),
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsPackageDescendants]
    ) {
        for case let candidate as URL in enumerator
        where candidate.lastPathComponent == name && access(candidate.path, X_OK) == 0 {
            return candidate.path
        }
    }
    throw CLITestError.binaryNotFound(name)
}

func createMarker(_ url: URL) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
        throw CLITestError.markerTimeout(url.path)
    }
}

func readProcessIdentifier(from marker: URL) throws -> Int32 {
    let value = try String(contentsOf: marker, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let processIdentifier = Int32(value) else {
        throw CLITestError.markerTimeout(marker.path)
    }
    return processIdentifier
}

func terminate(_ process: Process) {
    if process.isRunning {
        _ = kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}

func waitForMarker(
    _ marker: URL,
    process: CLIProcess,
    timeout: Duration = .seconds(5)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if access(marker.path, F_OK) == 0 { return }
        guard process.process.isRunning else {
            process.process.waitUntilExit()
            throw CLITestError.processExitedEarly(
                status: process.process.terminationStatus,
                output: process.errorText() + process.outputText()
            )
        }
        try await clock.sleep(for: .milliseconds(20))
    }
    throw CLITestError.markerTimeout(marker.path)
}

func waitForMetadata(
    at path: URL,
    coordinatorPID: Int32,
    timeout: Duration = .seconds(5)
) async throws -> LockMetadata {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if let data = try? Data(contentsOf: path),
           let metadata = try? JSONDecoder().decode(LockMetadata.self, from: data),
           metadata.coordinatorPID == coordinatorPID {
            return metadata
        }
        try await clock.sleep(for: .milliseconds(20))
    }
    throw CLITestError.markerTimeout("metadata at \(path.path)")
}

func waitForProcessGroupExit(
    _ processGroup: Int32,
    timeout: Duration = .seconds(5)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        errno = 0
        if kill(-processGroup, 0) == -1, errno == ESRCH {
            return
        }
        try await clock.sleep(for: .milliseconds(20))
    }
    throw CLITestError.processGroupTimeout(processGroup)
}

func waitForProcessExit(
    _ process: Process,
    timeout: Duration = .seconds(5)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if !process.isRunning {
            return
        }
        try await clock.sleep(for: .milliseconds(20))
    }
    throw CLITestError.processTimeout(process.processIdentifier)
}

func runRawProcess(
    executablePath: String,
    argumentBytes: [[UInt8]],
    environment: [String: String]
) throws -> Int32 {
    let argumentStorage = try argumentBytes.map(allocateCString)
    let environmentStorage = try environment.sorted(by: { $0.key < $1.key }).map {
        try allocateCString(Array("\($0.key)=\($0.value)".utf8))
    }
    defer {
        for pointer in argumentStorage + environmentStorage {
            free(pointer)
        }
    }

    var arguments: [UnsafeMutablePointer<CChar>?] = argumentStorage + [nil]
    var environmentValues: [UnsafeMutablePointer<CChar>?] = environmentStorage + [nil]
    var processIdentifier: pid_t = 0
    let spawnResult = executablePath.withCString { executable in
        arguments.withUnsafeMutableBufferPointer { arguments in
            environmentValues.withUnsafeMutableBufferPointer { environmentValues in
                posix_spawn(
                    &processIdentifier,
                    executable,
                    nil,
                    nil,
                    arguments.baseAddress,
                    environmentValues.baseAddress
                )
            }
        }
    }
    guard spawnResult == 0 else {
        throw CLITestError.systemCall(
            operation: "posix_spawn",
            errorNumber: spawnResult
        )
    }

    var status: Int32 = 0
    while waitpid(processIdentifier, &status, 0) == -1 {
        guard errno == EINTR else {
            throw CLITestError.systemCall(operation: "waitpid", errorNumber: errno)
        }
    }
    let terminationSignal = status & 0x7f
    if terminationSignal == 0 {
        return (status >> 8) & 0xff
    }
    return 128 + terminationSignal
}

private func allocateCString(_ bytes: [UInt8]) throws -> UnsafeMutablePointer<CChar> {
    guard !bytes.contains(0),
          let rawPointer = malloc(bytes.count + 1) else {
        throw CLITestError.systemCall(operation: "malloc", errorNumber: ENOMEM)
    }
    let pointer = rawPointer.assumingMemoryBound(to: CChar.self)
    for (index, byte) in bytes.enumerated() {
        pointer[index] = CChar(bitPattern: byte)
    }
    pointer[bytes.count] = 0
    return pointer
}

func fillPipe(_ pipe: Pipe) throws {
    let descriptor = pipe.fileHandleForWriting.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw CLITestError.systemCall(operation: "fcntl(pipeWrite)", errorNumber: errno)
    }
    defer { _ = fcntl(descriptor, F_SETFL, flags) }

    let buffer = [UInt8](repeating: 0x78, count: 4_096)
    try buffer.withUnsafeBytes { bytes in
        while true {
            let result = Darwin.write(descriptor, bytes.baseAddress, bytes.count)
            if result > 0 {
                continue
            }
            if result == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            if result == -1, errno == EINTR {
                continue
            }
            throw CLITestError.systemCall(
                operation: "write(pipe)",
                errorNumber: result == 0 ? EIO : errno
            )
        }
    }
}

func drainAvailablePipeData(_ pipe: Pipe) throws {
    let descriptor = pipe.fileHandleForReading.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw CLITestError.systemCall(operation: "fcntl(pipeRead)", errorNumber: errno)
    }
    defer { _ = fcntl(descriptor, F_SETFL, flags) }

    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let result = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if result > 0 {
            continue
        }
        if result == 0 || result == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            return
        }
        if result == -1, errno == EINTR {
            continue
        }
        throw CLITestError.systemCall(operation: "read(pipe)", errorNumber: errno)
    }
}
