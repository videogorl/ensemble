import Foundation

/// A cooperative deadline shared by refresh orchestration and provider pagination.
enum RefreshExecution {
    @TaskLocal static var deadline: TimeInterval?

    static var remainingTime: TimeInterval? {
        deadline.map { max(0, $0 - ProcessInfo.processInfo.systemUptime) }
    }

    static func checkCancellation() throws {
        try Task.checkCancellation()
        if let remainingTime, remainingTime <= 0 { throw CancellationError() }
    }

    @MainActor
    static func withBudget<Value: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @MainActor @Sendable () async -> Value
    ) async -> Value {
        let cutoff = min(deadline ?? .greatestFiniteMagnitude,
                         ProcessInfo.processInfo.systemUptime + max(0, seconds))
        return await $deadline.withValue(cutoff) {
            let work = Task { @MainActor in await operation() }
            let expiration = Task {
                do {
                    let remaining = max(0, cutoff - ProcessInfo.processInfo.systemUptime)
                    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    work.cancel()
                } catch {}
            }
            defer { expiration.cancel() }
            return await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
        }
    }
}

struct BackgroundRefreshIncompleteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
