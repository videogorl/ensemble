import Foundation

/// One piece of start-up work (restoring the Focus filter) that many callers need finished before they read what it
/// governs. Every caller awaits the same run, for at most `timeout`; the work is done only once it has finished, so a
/// caller that times out learns it is not done (and fails closed) and a later caller joins the same run instead of
/// starting another.
@MainActor
public final class SharedRestoration {
    public private(set) var isDone = false
    private var run: Task<Void, Never>?

    public init() {}

    /// Whether the work has finished, waiting up to `timeout` for it.
    public func ensure(timeout: Duration, work: @escaping @MainActor () async -> Void) async -> Bool {
        if isDone { return true }
        let current = run ?? Task { @MainActor in
            await work()
            isDone = true
            run = nil
        }
        run = current
        let (finished, signal) = AsyncStream.makeStream(of: Void.self)
        let waiter = Task { await current.value; signal.yield() }
        let deadline = Task { try? await Task.sleep(for: timeout); signal.yield() }
        await finished.first { _ in true }
        waiter.cancel()
        deadline.cancel()
        return isDone
    }
}
