import Foundation

public enum InheritedLeaseManifestError: Error, Equatable, Sendable {
    case duplicateDescriptor(Int32)
    case duplicateResource(String)
    case encodedValueTooLarge(Int)
    case invalidCount(Int)
    case invalidDescriptor(Int32)
    case invalidEncoding
    case invalidPath(String)
    case invalidSchemaVersion(Int)
    case unsortedResources

    public var failure: AgentLeaseFailure {
        AgentLeaseFailure(
            kind: .environment,
            operation: "leaseDescriptorManifest",
            message: String(describing: self)
        )
    }
}

public struct InheritedLeaseDescriptor: Codable, Equatable, Sendable {
    public let resource: String
    public let mode: LeaseMode
    public let descriptor: Int32
    public let path: String

    public init(resource: String, mode: LeaseMode, descriptor: Int32, path: String) {
        self.resource = resource
        self.mode = mode
        self.descriptor = descriptor
        self.path = path
    }
}

public struct InheritedLeaseManifest: Codable, Equatable, Sendable {
    public static let environmentKey = "AGENTLEASE_LEASE_DESCRIPTORS"
    public static let maximumEncodedBytes = 131_072
    public static let maximumPathBytes = 4_096

    public let schemaVersion: Int
    public let leases: [InheritedLeaseDescriptor]

    public init(schemaVersion: Int = 1, leases: [InheritedLeaseDescriptor]) {
        self.schemaVersion = schemaVersion
        self.leases = leases
    }

    public func environmentValue() throws -> String {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else {
            throw InheritedLeaseManifestError.encodedValueTooLarge(data.count)
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw InheritedLeaseManifestError.invalidEncoding
        }
        return value
    }

    public static func decodeEnvironmentValue(_ value: String) throws -> Self {
        let data = Data(value.utf8)
        guard data.count <= maximumEncodedBytes else {
            throw InheritedLeaseManifestError.encodedValueTooLarge(data.count)
        }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw InheritedLeaseManifestError.invalidSchemaVersion(schemaVersion)
        }
        guard (1...ResourceSet.maximumCount).contains(leases.count) else {
            throw InheritedLeaseManifestError.invalidCount(leases.count)
        }

        var previousResource: ResourceName?
        var resources = Set<ResourceName>()
        var descriptors = Set<Int32>()
        for lease in leases {
            let resource = try ResourceName(lease.resource)
            if let previousResource, !(previousResource < resource) {
                if previousResource == resource {
                    throw InheritedLeaseManifestError.duplicateResource(resource.value)
                }
                throw InheritedLeaseManifestError.unsortedResources
            }
            guard resources.insert(resource).inserted else {
                throw InheritedLeaseManifestError.duplicateResource(resource.value)
            }
            guard lease.descriptor >= FileLock.minimumOwnedDescriptor else {
                throw InheritedLeaseManifestError.invalidDescriptor(lease.descriptor)
            }
            guard descriptors.insert(lease.descriptor).inserted else {
                throw InheritedLeaseManifestError.duplicateDescriptor(lease.descriptor)
            }
            guard Self.isValidPath(lease.path, resource: resource) else {
                throw InheritedLeaseManifestError.invalidPath(lease.path)
            }
            previousResource = resource
        }
    }

    private static func isValidPath(_ path: String, resource: ResourceName) -> Bool {
        guard path.first == "/",
              path.utf8.count <= maximumPathBytes,
              !path.unicodeScalars.contains(where: { scalar in
                  (0x00...0x1F).contains(scalar.value)
                      || (0x7F...0x9F).contains(scalar.value)
              }),
              path.hasSuffix("/locks/\(resource.lockFileName)") else {
            return false
        }
        return true
    }
}
