import CryptoKit
import Foundation

public enum ResourceValidationError: Error, Equatable, Sendable {
    case duplicate(String)
    case emptySet
    case environmentRepresentationTooLarge(Int)
    case invalid(String)
    case tooMany(Int)
}

public struct ResourceName: Codable, Comparable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard (1...256).contains(bytes.count),
              bytes.allSatisfy({ $0 < 0x80 }),
              let first = bytes.first,
              Self.isASCIIAlphanumeric(first),
              bytes.dropFirst().allSatisfy(Self.isAllowedContinuation) else {
            throw ResourceValidationError.invalid(value)
        }
        self.value = value
    }

    public var lockDigest: String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var lockFileName: String {
        "\(lockDigest).lock"
    }

    public static func < (lhs: ResourceName, rhs: ResourceName) -> Bool {
        lhs.value.utf8.lexicographicallyPrecedes(rhs.value.utf8)
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
    }

    private static func isAllowedContinuation(_ byte: UInt8) -> Bool {
        isASCIIAlphanumeric(byte)
            || byte == 0x2E
            || byte == 0x2F
            || byte == 0x3A
            || byte == 0x5F
            || byte == 0x2D
    }
}

public struct ResourceSet: Equatable, Sendable {
    public static let maximumCount = 64
    public static let maximumEnvironmentBytes = 4_096

    public let resources: [ResourceName]

    public init(_ values: [String]) throws {
        guard !values.isEmpty else {
            throw ResourceValidationError.emptySet
        }
        guard values.count <= Self.maximumCount else {
            throw ResourceValidationError.tooMany(values.count)
        }

        let validated = try values.map(ResourceName.init)
        var seen = Set<ResourceName>()
        for resource in validated where !seen.insert(resource).inserted {
            throw ResourceValidationError.duplicate(resource.value)
        }

        let sorted = validated.sorted()
        let representation = sorted.map(\.value).joined(separator: ",")
        guard representation.utf8.count <= Self.maximumEnvironmentBytes else {
            throw ResourceValidationError.environmentRepresentationTooLarge(
                representation.utf8.count
            )
        }
        resources = sorted
    }

    public var environmentValue: String {
        resources.map(\.value).joined(separator: ",")
    }
}
