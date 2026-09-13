import Darwin
import Foundation

enum AgentLeaseTestError: Error, CustomStringConvertible {
    case helperNotFound
    case markerTimeout(String)
    case processFailed(String)
    case systemCall(String, Int32)

    var description: String {
        switch self {
        case .helperNotFound:
            "agentlease-spike-helper was not found"
        case .markerTimeout(let path):
            "timed out waiting for marker at \(path)"
        case .processFailed(let message):
            message
        case .systemCall(let operation, let code):
            "\(operation) failed with errno \(code)"
        }
    }
}

struct HelperProcess {
    let output: Pipe
    let process: Process

    func readOutput() -> String {
        String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? "<non-UTF-8 output>"
    }
}

func agentLeaseHelperPath() throws -> String {
    let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let conventionalPath = packageRoot
        .appendingPathComponent(".build/debug/agentlease-spike-helper")
        .path
    if access(conventionalPath, X_OK) == 0 {
        return conventionalPath
    }

    let buildRoot = packageRoot.appendingPathComponent(".build", isDirectory: true)
    if let enumerator = FileManager.default.enumerator(
        at: buildRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsPackageDescendants]
    ) {
        for case let candidate as URL in enumerator
        where candidate.lastPathComponent == "agentlease-spike-helper"
            && access(candidate.path, X_OK) == 0 {
            return candidate.path
        }
    }
    throw AgentLeaseTestError.helperNotFound
}

func launchAgentLeaseHelper(_ arguments: [String]) throws -> HelperProcess {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: try agentLeaseHelperPath())
    process.arguments = arguments
    process.standardError = output
    process.standardOutput = output
    try process.run()
    return HelperProcess(output: output, process: process)
}

func makeAgentLeaseTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("agentlease-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

func makeMarker(at url: URL) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
        throw AgentLeaseTestError.processFailed("could not create marker at \(url.path)")
    }
}

func waitForMarker(
    at url: URL,
    processes: [HelperProcess] = [],
    timeout: Duration = .seconds(5)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if access(url.path, F_OK) == 0 {
            return
        }
        if let exited = processes.first(where: { !$0.process.isRunning }) {
            exited.process.waitUntilExit()
            throw AgentLeaseTestError.processFailed(
                "helper exited \(exited.process.terminationStatus):\n\(exited.readOutput())"
            )
        }
        try await clock.sleep(for: .milliseconds(20))
    }
    throw AgentLeaseTestError.markerTimeout(url.path)
}

func waitForEitherMarker(
    _ first: URL,
    _ second: URL,
    processes: [HelperProcess],
    timeout: Duration = .seconds(5)
) async throws -> URL {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if access(first.path, F_OK) == 0 { return first }
        if access(second.path, F_OK) == 0 { return second }
        if let exited = processes.first(where: { !$0.process.isRunning }) {
            exited.process.waitUntilExit()
            throw AgentLeaseTestError.processFailed(
                "helper exited \(exited.process.terminationStatus):\n\(exited.readOutput())"
            )
        }
        try await clock.sleep(for: .milliseconds(20))
    }
    throw AgentLeaseTestError.markerTimeout("\(first.path) or \(second.path)")
}

func terminateIfRunning(_ helper: HelperProcess) {
    if helper.process.isRunning {
        _ = kill(helper.process.processIdentifier, SIGKILL)
        helper.process.waitUntilExit()
    }
}
