/// Fans one owner's values out to any number of async listeners.
///
/// A service keeps its state in one snapshot value and sends each change here;
/// listeners call `stream(startingWith:)` to get the current snapshot first, as
/// `@Published` did. Every listener receives every value in order, so
/// `dropFirst()` always skips exactly the starting value.
@MainActor
public final class Broadcast<Value: Sendable> {
    private var continuations: [Int: AsyncStream<Value>.Continuation] = [:]
    private var nextID = 0

    public init() {}

    public func stream(startingWith first: Value? = nil) -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self)
        let id = nextID
        nextID += 1
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        if let first { continuation.yield(first) }
        return stream
    }

    public func send(_ value: Value) {
        for continuation in continuations.values {
            continuation.yield(value)
        }
    }

    deinit {
        for continuation in continuations.values {
            continuation.finish()
        }
    }
}

/// Keeps an `observe` loop running; releasing it cancels the loop.
/// Owners store these the way they stored `AnyCancellable`.
public final class StreamSubscription: Sendable {
    private let task: Task<Void, Never>

    init(_ task: Task<Void, Never>) {
        self.task = task
    }

    public func cancel() {
        task.cancel()
    }

    deinit {
        task.cancel()
    }
}

public extension AsyncSequence where Self: Sendable, Element: Sendable {
    /// Runs `body` on the main actor for each element while `owner` is alive.
    func observe<Owner: AnyObject>(
        _ owner: Owner,
        _ body: @escaping @MainActor (Owner, Element) async -> Void
    ) -> StreamSubscription {
        StreamSubscription(Task { @MainActor [weak owner] in
            do {
                for try await element in self {
                    guard let owner else { return }
                    await body(owner, element)
                }
            } catch {}
        })
    }
}
