import Darwin
import Foundation

public struct AgentLeaseFailure: Codable, Equatable, Error, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case acquisitionTimeout
        case cancelled
        case environment
        case executableNotFound
        case executableNotRunnable
        case exec
        case `internal`
        case lockIO
        case recordPublication
        case resourceLimit
        case spawn
        case stateIO
        case unsafeState
    }

    public let kind: Kind
    public let operation: String
    public let errorNumber: Int32?
    public let resource: String?
    public let message: String

    public init(
        kind: Kind,
        operation: String,
        errorNumber: Int32? = nil,
        resource: String? = nil,
        message: String
    ) {
        self.kind = kind
        self.operation = Self.bounded(operation)
        self.errorNumber = errorNumber
        self.resource = resource.map { Self.bounded($0) }
        self.message = Self.bounded(Self.sanitized(message))
    }

    public static func systemMessage(for errorNumber: Int32) -> String {
        sanitized(String(cString: strerror(errorNumber)))
    }

    public static func sanitized(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            let value = scalar.value
            if value <= 0x1F || (0x7F...0x9F).contains(value) {
                return "�"
            }
            return Character(String(scalar))
        })
    }

    public static func bounded(_ value: String, maximumUTF8Bytes: Int = 512) -> String {
        guard value.utf8.count > maximumUTF8Bytes else { return value }

        var result = ""
        result.reserveCapacity(maximumUTF8Bytes)
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumUTF8Bytes else { break }
            result = candidate
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case errorNumber = "errno"
        case kind
        case message
        case operation
        case resource
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(operation, forKey: .operation)
        if let errorNumber {
            try container.encode(errorNumber, forKey: .errorNumber)
        } else {
            try container.encodeNil(forKey: .errorNumber)
        }
        if let resource {
            try container.encode(resource, forKey: .resource)
        } else {
            try container.encodeNil(forKey: .resource)
        }
        try container.encode(message, forKey: .message)
    }
}

extension AgentLeaseFailure: CustomStringConvertible {
    public var description: String {
        var components = ["\(kind.rawValue): \(message)", "operation=\(operation)"]
        if let errorNumber {
            components.append("errno=\(errorNumber)")
        }
        if let resource {
            components.append("resource=\(resource)")
        }
        return components.joined(separator: ", ")
    }
}
