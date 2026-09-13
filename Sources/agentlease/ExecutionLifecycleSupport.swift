import AgentLeaseCore
import Foundation
import Synchronization

struct MetadataContext: Sendable {
    let acquiredAt: String
    let bead: String?
    let coordinatorPID: Int32
    let label: String?
    let mode: ExecutionMode
    let runID: String

    func value(
        resource: ResourceName,
        state: RunState,
        childPID: Int32?
    ) -> LockMetadata {
        LockMetadata(
            resourceName: resource.value,
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
}

final class RunRecordPublication: Sendable {
    private let fileName: String
    private let record: Mutex<RunRecord>
    private let store: AtomicJSONStore

    init(initialRecord: RunRecord, store: AtomicJSONStore) {
        fileName = "\(initialRecord.runID).json"
        record = Mutex(initialRecord)
        self.store = store
    }

    func publishAcquired() throws {
        try update { record in
            record.state = .acquired
        }
    }

    func publishFailure(
        state: RunState,
        failure: AgentLeaseFailure?,
        receivedSignal: Int32?,
        childPID: Int32? = nil
    ) throws {
        try update { record in
            record.state = state
            if let childPID {
                record.childPID = childPID
            }
            record.finishedAt = RunRecord.timestamp()
            record.receivedSignal = receivedSignal
            record.termination = nil
            record.failure = failure
        }
    }

    func publishHandoffPrepared() throws {
        try update { record in
            record.state = .handoffPrepared
        }
    }

    func publishInitial() throws {
        try record.withLock { record in
            try store.replace(record, named: fileName)
        }
    }

    func publishRunning(childPID: Int32) throws {
        try update { record in
            record.state = .running
            record.childPID = childPID
        }
    }

    func publishTerminal(state: RunState, termination: RunTermination) throws {
        try update { record in
            record.state = state
            record.finishedAt = RunRecord.timestamp()
            record.termination = termination
            record.failure = nil
        }
    }

    private func update(_ mutation: (inout RunRecord) -> Void) throws {
        try record.withLock { record in
            var candidate = record
            mutation(&candidate)
            try store.replace(candidate, named: fileName)
            record = candidate
        }
    }
}

func reportContention(
    resource: ResourceName,
    metadataRead: BoundedMetadataRead
) {
    var owner = ""
    if case .data(let data) = metadataRead,
       let metadata = try? JSONDecoder().decode(LockMetadata.self, from: data),
       metadata.resourceName == resource.value {
        let label = metadata.label.map { " label=\($0)" } ?? ""
        owner = " (last owner run=\(metadata.runID)\(label))"
    }
    stderr("waiting for resource \(resource.value)\(owner)")
}

func reportMetadataIssues(_ lease: LeaseSet) {
    let issues = lease.takeMetadataWriteIssues()
    guard let first = issues.first else { return }
    stderr(
        "metadata update failed for \(issues.count) resource(s); "
            + "first: \(first.failure.description)"
    )
}

func stderr(_ message: String) {
    let sanitized = AgentLeaseFailure.bounded(AgentLeaseFailure.sanitized(message))
    FileHandle.standardError.write(Data("agentlease: \(sanitized)\n".utf8))
}
