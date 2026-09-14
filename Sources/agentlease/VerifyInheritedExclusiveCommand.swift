import AgentLeaseCore
import ArgumentParser

struct VerifyInheritedExclusiveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify-inherited-exclusive",
        abstract: "Validate and establish one inherited exclusive lease.",
        shouldDisplay: false
    )

    @Option(name: .long, help: "Exact inherited resource to verify.")
    var resource: String

    mutating func run() throws {
        do {
            try InheritedExclusiveLeaseGuard.establish(resource: resource)
        } catch let error as InheritedExclusiveLeaseGuardError {
            stderr(error.failure.description)
            throw ExitCode(70)
        } catch {
            stderr(String(describing: error))
            throw ExitCode(70)
        }
    }
}
