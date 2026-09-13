import CryptoKit
import Foundation

public enum ArgumentCommitment {
    private static let domain = Data("agentlease.argv.v1\0".utf8)

    public static func digest(arguments: [String]) -> String {
        var input = domain
        for argument in arguments {
            let bytes = Data(argument.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(bytes)
        }
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}
