import Darwin
import Dispatch
import Synchronization

final class SignalRelay: @unchecked Sendable {
    enum RelayError: Error {
        case systemCall(operation: String, signal: Int32, errorNumber: Int32)
    }

    private struct State {
        var firstSignal: Int32?
        var restored = false
    }

    private let continuation: AsyncStream<Int32>.Continuation
    private let previousActions: [(Int32, sigaction)]
    private var sources: [DispatchSourceSignal] = []
    private let state = Mutex(State())
    let stream: AsyncStream<Int32>

    init(signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]) throws {
        let pair = AsyncStream.makeStream(of: Int32.self)
        stream = pair.stream
        continuation = pair.continuation

        var savedActions: [(Int32, sigaction)] = []
        do {
            for signalNumber in signals {
                var previous = sigaction()
                guard sigaction(signalNumber, nil, &previous) == 0 else {
                    throw RelayError.systemCall(
                        operation: "sigaction(get)",
                        signal: signalNumber,
                        errorNumber: errno
                    )
                }
                savedActions.append((signalNumber, previous))
                var ignored = sigaction()
                ignored.__sigaction_u.__sa_handler = SIG_IGN
                guard sigemptyset(&ignored.sa_mask) == 0,
                      sigaction(signalNumber, &ignored, nil) == 0 else {
                    throw RelayError.systemCall(
                        operation: "signal(ignore)",
                        signal: signalNumber,
                        errorNumber: errno
                    )
                }
            }
        } catch {
            for (signalNumber, var action) in savedActions.reversed() {
                _ = sigaction(signalNumber, &action, nil)
            }
            throw error
        }
        previousActions = savedActions

        for signalNumber in signals {
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: DispatchQueue.global(qos: .userInitiated)
            )
            source.setEventHandler { [weak self] in
                self?.receive(signalNumber)
            }
            sources.append(source)
            source.resume()
        }
    }

    deinit {
        restore()
    }

    var firstSignal: Int32? {
        state.withLock { $0.firstSignal }
    }

    func nextSignal() async -> Int32? {
        await withTaskCancellationHandler {
            for await signalNumber in stream {
                return signalNumber
            }
            return nil
        } onCancel: {
            continuation.finish()
        }
    }

    func restore() {
        let shouldRestore = state.withLock { state in
            guard !state.restored else { return false }
            state.restored = true
            return true
        }
        guard shouldRestore else { return }

        for source in sources {
            source.cancel()
        }
        for (signalNumber, var action) in previousActions {
            _ = sigaction(signalNumber, &action, nil)
        }
        continuation.finish()
    }

    private func receive(_ signalNumber: Int32) {
        let isFirst = state.withLock { state in
            guard state.firstSignal == nil, !state.restored else { return false }
            state.firstSignal = signalNumber
            return true
        }
        if isFirst {
            continuation.yield(signalNumber)
            continuation.finish()
        }
    }
}
