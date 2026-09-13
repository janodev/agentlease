import AgentLeaseCore
import ArgumentParser
import Foundation

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show kernel ownership and diagnostic last-owner metadata."
    )

    @Flag(name: .long, help: "Emit stable versioned JSON.")
    var json = false

    mutating func run() throws {
        let paths: AgentLeasePaths
        do {
            paths = try AgentLeasePaths.open()
        } catch let error as AgentLeasePathError {
            stderr(error.failure.description)
            throw ExitCode(70)
        } catch {
            stderr(String(describing: error))
            throw ExitCode(70)
        }

        let result = StatusProbe.inspect(paths: paths)
        if json {
            try writeJSON(result.report)
        } else {
            writeHuman(result.report)
        }
        if result.requiresFailureExit {
            throw ExitCode(70)
        }
    }

    private func writeHuman(_ report: StatusReport) {
        if report.entries.isEmpty {
            stdout("no lock entries in \(report.stateRoot)")
        }
        for entry in report.entries {
            let identity = entry.resource
                ?? entry.digest
                ?? AgentLeaseFailure.bounded(AgentLeaseFailure.sanitized(entry.fileName))
            var line = "\(entry.availability.rawValue) \(identity)"
                + " metadata=\(entry.metadataStatus.rawValue)"
            if let owner = entry.lastOwner {
                let ownerKey = entry.availability == .free ? "historical-run" : "run"
                line += " \(ownerKey)=\(owner.runID)"
                if let label = owner.label {
                    line += " label=\(label)"
                }
            }
            if let error = entry.error {
                line += " error=\(error.description)"
            }
            stdout(line)
        }
        for error in report.errors {
            stdout("error \(error.description)")
        }
    }

    private func writeJSON(_ report: StatusReport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(report)
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }

    private func stdout(_ message: String) {
        FileHandle.standardOutput.write(Data("\(message)\n".utf8))
    }
}
