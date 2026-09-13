import Foundation

public enum ExecutionMode: String, Codable, Sendable {
    case exec
    case run
}

public enum RunState: String, Codable, Sendable {
    case acquired
    case acquiring
    case exited
    case failed
    case handoffPrepared
    case running
    case signalled
}

public struct RunTermination: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case exit
        case signal
    }

    public let kind: Kind
    public let value: Int32

    public init(kind: Kind, value: Int32) {
        self.kind = kind
        self.value = value
    }
}

public struct RunRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let runID: String
    public let mode: ExecutionMode
    public var state: RunState
    public let resources: [String]
    public let label: String?
    public let bead: String?
    public let coordinatorPID: Int32
    public var childPID: Int32?
    public let workingDirectory: String
    public let executable: String
    public let resolvedExecutable: String
    public let argumentCommitment: String
    public let arguments: [String]?
    public let startedAt: String
    public var finishedAt: String?
    public var receivedSignal: Int32?
    public var termination: RunTermination?
    public var failure: AgentLeaseFailure?

    public init(
        schemaVersion: Int = 1,
        runID: String,
        mode: ExecutionMode,
        state: RunState,
        resources: [String],
        label: String?,
        bead: String?,
        coordinatorPID: Int32,
        childPID: Int32?,
        workingDirectory: String,
        executable: String,
        resolvedExecutable: String,
        argumentCommitment: String,
        arguments: [String]?,
        startedAt: String,
        finishedAt: String?,
        receivedSignal: Int32?,
        termination: RunTermination?,
        failure: AgentLeaseFailure?
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.mode = mode
        self.state = state
        self.resources = resources
        self.label = label
        self.bead = bead
        self.coordinatorPID = coordinatorPID
        self.childPID = childPID
        self.workingDirectory = workingDirectory
        self.executable = executable
        self.resolvedExecutable = resolvedExecutable
        self.argumentCommitment = argumentCommitment
        self.arguments = arguments
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.receivedSignal = receivedSignal
        self.termination = termination
        self.failure = failure
    }

    public static func timestamp() -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date())
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(runID, forKey: .runID)
        try container.encode(mode, forKey: .mode)
        try container.encode(state, forKey: .state)
        try container.encode(resources, forKey: .resources)
        try container.encodeNullable(label, forKey: .label)
        try container.encodeNullable(bead, forKey: .bead)
        try container.encode(coordinatorPID, forKey: .coordinatorPID)
        try container.encodeNullable(childPID, forKey: .childPID)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(executable, forKey: .executable)
        try container.encode(resolvedExecutable, forKey: .resolvedExecutable)
        try container.encode(argumentCommitment, forKey: .argumentCommitment)
        try container.encodeNullable(arguments, forKey: .arguments)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeNullable(finishedAt, forKey: .finishedAt)
        try container.encodeNullable(receivedSignal, forKey: .receivedSignal)
        try container.encodeNullable(termination, forKey: .termination)
        try container.encodeNullable(failure, forKey: .failure)
    }
}

public struct LockMetadata: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let resourceName: String
    public let runID: String
    public let coordinatorPID: Int32
    public let childPID: Int32?
    public let mode: ExecutionMode
    public let state: RunState
    public let label: String?
    public let bead: String?
    public let acquiredAt: String

    public init(
        schemaVersion: Int = 1,
        resourceName: String,
        runID: String,
        coordinatorPID: Int32,
        childPID: Int32?,
        mode: ExecutionMode,
        state: RunState,
        label: String?,
        bead: String?,
        acquiredAt: String
    ) {
        self.schemaVersion = schemaVersion
        self.resourceName = resourceName
        self.runID = runID
        self.coordinatorPID = coordinatorPID
        self.childPID = childPID
        self.mode = mode
        self.state = state
        self.label = label
        self.bead = bead
        self.acquiredAt = acquiredAt
    }

    public func replacing(
        state: RunState,
        childPID: Int32? = nil
    ) -> LockMetadata {
        LockMetadata(
            schemaVersion: schemaVersion,
            resourceName: resourceName,
            runID: runID,
            coordinatorPID: coordinatorPID,
            childPID: childPID,
            mode: mode,
            state: state,
            label: label,
            bead: bead,
            acquiredAt: acquiredAt
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(resourceName, forKey: .resourceName)
        try container.encode(runID, forKey: .runID)
        try container.encode(coordinatorPID, forKey: .coordinatorPID)
        try container.encodeNullable(childPID, forKey: .childPID)
        try container.encode(mode, forKey: .mode)
        try container.encode(state, forKey: .state)
        try container.encodeNullable(label, forKey: .label)
        try container.encodeNullable(bead, forKey: .bead)
        try container.encode(acquiredAt, forKey: .acquiredAt)
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
