import ArgumentParser

struct AgentLeaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentlease",
        abstract: "Run a command while holding named local resources.",
        version: "0.1.0-dev",
        subcommands: [RunCommand.self]
    )
}
