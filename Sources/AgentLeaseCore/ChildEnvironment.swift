import Foundation

public enum ChildEnvironment {
    public static let beadIDKey = "AGENTLEASE_BEAD_ID"
    public static let heldResourcesKey = "AGENTLEASE_HELD_RESOURCES"
    public static let runIDKey = "AGENTLEASE_RUN_ID"

    public static func build(
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        stateRoot: String,
        runID: String,
        resources: ResourceSet,
        bead: String?
    ) -> [String: String] {
        var environment = inherited
        environment[AgentLeasePaths.homeEnvironmentKey] = stateRoot
        environment[runIDKey] = runID
        environment[heldResourcesKey] = resources.environmentValue
        environment.removeValue(forKey: InheritedLeaseManifest.environmentKey)
        if let bead {
            environment[beadIDKey] = bead
        } else {
            environment.removeValue(forKey: beadIDKey)
        }
        return environment
    }

    public static func addingLeaseDescriptorManifest(
        _ leases: [InheritedLeaseDescriptor],
        to environment: [String: String]
    ) throws -> [String: String] {
        var environment = environment
        environment[InheritedLeaseManifest.environmentKey] = try InheritedLeaseManifest(
            leases: leases
        ).environmentValue()
        return environment
    }

    public static func isNested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let heldResources = environment[heldResourcesKey] else { return false }
        return !heldResources.isEmpty
    }
}
