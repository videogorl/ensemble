import Foundation

/// Plex keeps one direct-play session per client: a second original file request ends the
/// download in flight ("Terminated session ... Client stopped playback", -1005 on the phone).
/// The gate allows one direct download per server at a time. The track being played enters at
/// once; a prefetch waits for it to finish, and starts the moment it does.
final class DirectDownloadGate: @unchecked Sendable {
    static let shared = DirectDownloadGate()

    private let lock = NSLock()
    private var active: [String: Int] = [:]
    private var waiters: [String: [(id: UUID, continuation: CheckedContinuation<Void, Error>)]] = [:]

    /// The server a request goes to, as a gate key.
    static func key(for request: URLRequest) -> String? {
        guard let url = request.url, let host = url.host, !url.isFileURL else { return nil }
        return "\(host):\(url.port ?? 0)"
    }

    /// Takes the slot at once, without waiting: the track being played never queues.
    func enter(_ key: String) -> DirectDownloadSlot {
        lock.lock()
        active[key, default: 0] += 1
        lock.unlock()
        return DirectDownloadSlot(gate: self, key: key)
    }

    /// Waits until no direct download is active for the server, then takes the slot.
    /// Throws `CancellationError` if the task is cancelled while waiting.
    func acquire(_ key: String) async throws -> DirectDownloadSlot {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if active[key, default: 0] == 0 {
                    active[key] = 1
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters[key, default: []].append((id, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters[key]?.firstIndex { $0.id == id }.map { waiters[key]!.remove(at: $0) }
            lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
        return DirectDownloadSlot(gate: self, key: key)
    }

    fileprivate func leave(_ key: String) {
        lock.lock()
        let remaining = max(0, (active[key] ?? 0) - 1)
        var next: CheckedContinuation<Void, Error>?
        if remaining == 0, let first = waiters[key]?.first {
            waiters[key]?.removeFirst()
            next = first.continuation
            active[key] = 1
        } else {
            active[key] = remaining == 0 ? nil : remaining
        }
        lock.unlock()
        next?.resume()
    }
}

/// One direct download's hold on its server. Released when the download ends, or when the
/// holder is dropped without ever starting it.
final class DirectDownloadSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: DirectDownloadGate?
    private let key: String

    fileprivate init(gate: DirectDownloadGate, key: String) {
        self.gate = gate
        self.key = key
    }

    func release() {
        lock.lock()
        let gate = self.gate
        self.gate = nil
        lock.unlock()
        gate?.leave(key)
    }

    deinit { release() }
}
