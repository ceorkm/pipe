import Foundation
import Network

/// Small async layer over NWConnection. Every call is cancellable through the connection itself.
public extension NWConnection {
    /// Start the connection and wait until it is ready, failing with the transport error otherwise.
    /// On timeout the connection is cancelled, which drives the `.cancelled` state and resumes the
    /// wait with ETIMEDOUT. The continuation is resumed exactly once on every path.
    func startAndWaitReady(queue: DispatchQueue, timeout: TimeInterval) async throws {
        let done = LockedFlag()
        let timedOut = LockedFlag()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if done.trySet() { cont.resume() }
                case .failed(let error):
                    if done.trySet() { cont.resume(throwing: error) }
                case .waiting(let error):
                    // No usable path right now (refused, unreachable, DNS failed): fail fast.
                    if done.trySet() { cont.resume(throwing: error) }
                case .cancelled:
                    if done.trySet() { cont.resume(throwing: NWError.posix(timedOut.isSet ? .ETIMEDOUT : .ECANCELED)) }
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, !done.isSet else { return }
                _ = timedOut.trySet()
                self.cancel()
            }
            self.start(queue: queue)
        }
        self.stateUpdateHandler = nil
    }

    func sendAsync(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// Receive exactly `count` bytes.
    func receiveExactly(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            self.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                guard let data, data.count == count else {
                    cont.resume(throwing: ProxyError.protocolError(isComplete ? "connection closed by proxy" : "short read"))
                    return
                }
                cont.resume(returning: data)
            }
        }
    }

    /// Receive whatever is available, up to `max` bytes. Returns nil on clean EOF.
    func receiveSome(max: Int = 65536) async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            self.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if isComplete { cont.resume(returning: nil); return }
                cont.resume(returning: Data())
            }
        }
    }

    /// Receive one datagram (UDP). Returns nil on EOF.
    func receiveDatagram() async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            self.receiveMessage { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                if let data { cont.resume(returning: data); return }
                cont.resume(returning: isComplete ? nil : Data())
            }
        }
    }
}

/// One-shot flag so a continuation is resumed exactly once.
final class LockedFlag: @unchecked Sendable {
    private var set = false
    private let lock = NSLock()
    func trySet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if set { return false }
        set = true
        return true
    }
    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return set
    }
}
