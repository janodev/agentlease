import ArgumentParser

struct AgentLeaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentlease",
        abstract: "Coordinate commands with kernel-backed local resource leases.",
        version: "2.1.0",
        subcommands: [
            CleanupCommand.self,
            ExecCommand.self,
            RunCommand.self,
            StatusCommand.self,
            VerifyInheritedExclusiveCommand.self,
        ]
    )
}
