import AgentLeaseCore
import ArgumentParser

struct ExecutionOptions: ParsableArguments, Sendable {
    @Option(
        name: .long,
        help: "Named resource to own exclusively; repeat for multiple resources."
    )
    var resource: [String] = []

    @Option(name: .long, help: "Human-readable description stored in diagnostics.")
    var label: String?

    @Option(name: .long, help: "Opaque Bead correlation identifier.")
    var bead: String?

    @Option(name: .long, help: "Maximum acquisition time in seconds; waits forever by default.")
    var waitSeconds: Double?

    @Flag(name: .long, help: "Persist the full command argument array in the run record.")
    var recordArguments = false

    @Argument(
        parsing: .captureForPassthrough,
        help: "Executable and arguments following '--'."
    )
    var command: [String] = []

    mutating func validate() throws {
        guard command.first == "--" else {
            throw ValidationError("provide a command after '--'")
        }
        command.removeFirst()
        do {
            _ = try ResourceSet(resource)
            try TextFieldValidator.validate(label, field: "label")
            try TextFieldValidator.validate(bead, field: "bead")
        } catch {
            throw ValidationError(String(describing: error))
        }
        if let waitSeconds,
           !waitSeconds.isFinite || waitSeconds < 0 {
            throw ValidationError("--wait-seconds must be finite and nonnegative")
        }
        guard !command.isEmpty else {
            throw ValidationError("provide a command after '--'")
        }
    }
}
