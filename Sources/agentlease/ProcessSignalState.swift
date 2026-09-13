import Darwin
import Synchronization

enum ProcessSignalStateError: Error, Sendable {
    case maskNotCaptured
    case systemCall(operation: String, errorNumber: Int32)
}

enum ProcessSignalState {
    private struct State: @unchecked Sendable {
        var inheritedMask: sigset_t?
    }

    private static let state = Mutex(State())

    static func captureInheritedMask() throws {
        var mask = sigset_t()
        let result = pthread_sigmask(SIG_SETMASK, nil, &mask)
        guard result == 0 else {
            throw ProcessSignalStateError.systemCall(
                operation: "pthread_sigmask(capture)",
                errorNumber: result
            )
        }
        state.withLock { $0.inheritedMask = mask }
    }

    static func restoreInheritedMask() throws {
        guard var mask = state.withLock({ $0.inheritedMask }) else {
            throw ProcessSignalStateError.maskNotCaptured
        }
        let result = pthread_sigmask(SIG_SETMASK, &mask, nil)
        guard result == 0 else {
            throw ProcessSignalStateError.systemCall(
                operation: "pthread_sigmask(restore)",
                errorNumber: result
            )
        }
    }
}
