import AgentLeaseCore
import ArgumentParser
import Foundation

struct CleanupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Preview or retire old kernel-free registry records and resource locks."
    )

    @Flag(name: .long, help: "Remove eligible entries; the default only previews.")
    var execute = false

    @Flag(name: .long, help: "Emit a structured JSON summary.")
    var json = false

    @Option(name: .long, help: "Retention age in days (default: 7).")
    var olderThanDays: Double = 7

    @Option(name: .long, help: "Preserve a lowercase SHA-256 resource-lock digest; repeatable.")
    var keepLockDigest: [String] = []

    @Option(name: .long, help: "Preserve an exact canonical lock path in this state root; repeatable.")
    var keepLockPath: [String] = []

    @Option(name: .long, help: "Preserve a diagnostic run UUID; repeatable.")
    var keepRunID: [String] = []

    mutating func validate() throws {
        guard olderThanDays.isFinite, olderThanDays >= 0 else {
            throw ValidationError("--older-than-days must be finite and nonnegative")
        }
        guard keepLockDigest.count + keepLockPath.count + keepRunID.count <= LeaseCleanup.maximumProtectionCount else {
            throw ValidationError("at most 1024 protections are allowed")
        }
    }

    mutating func run() throws {
        do {
            let paths = try AgentLeasePaths.open()
            let report = try LeaseCleanup.perform(paths: paths, options: CleanupOptions(
                execute: execute, olderThanDays: olderThanDays,
                protectedLockDigests: Set(keepLockDigest),
                protectedLockPaths: Set(keepLockPath), protectedRunIDs: Set(keepRunID)
            ))
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var data = try encoder.encode(report)
                data.append(0x0a)
                FileHandle.standardOutput.write(data)
            } else if report.busy {
                print("Cleanup skipped: registry acquisition or inspection is in progress.")
            } else {
                print("\(execute ? "Removed" : "Eligible"): \(execute ? report.removedCount : report.eligibleCount); kept: \(report.entries.filter { $0.action == .kept }.count); errors: \(report.errors.count)")
            }
            if !report.errors.isEmpty { throw ExitCode(70) }
        } catch let code as ExitCode {
            throw code
        } catch {
            stderr(String(describing: error))
            throw ExitCode(70)
        }
    }
}
