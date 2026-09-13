import ArgumentParser
import Darwin
import Foundation

@main
enum AgentLeaseMain {
    static func main() async {
        guard rawArgumentsAreValidUTF8() else {
            FileHandle.standardError.write(
                Data("agentlease: command arguments must be valid UTF-8\n".utf8)
            )
            Darwin.exit(64)
        }
        await AgentLeaseCommand.main()
    }

    private static func rawArgumentsAreValidUTF8() -> Bool {
        for index in 0..<Int(CommandLine.argc) {
            guard let pointer = CommandLine.unsafeArgv[index] else { return false }
            let count = strlen(pointer)
            let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
            let buffer = UnsafeBufferPointer(start: bytes, count: count)
            guard String(bytes: buffer, encoding: .utf8) != nil else { return false }
        }
        return true
    }
}
