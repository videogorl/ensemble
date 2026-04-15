import Foundation

/// Owns debounced download-change notifications and queue-completion toasts so
/// OfflineDownloadService does not mix queue/target logic with UI-facing fan-out.
@MainActor
final class OfflineDownloadNotificationBridge {
    struct Dependencies {
        let fetchPendingDownloadCount: @Sendable () async -> Int
        let refreshActiveDownloadRatingKeys: @Sendable () async -> Void
        let refreshViewContext: @MainActor () -> Void
        let postDownloadsDidChange: @MainActor () -> Void
        let showCompletionToast: @MainActor () -> Void
    }

    private let dependencies: Dependencies
    private let shortDebounceNanoseconds: UInt64
    private let bulkDebounceNanoseconds: UInt64
    private var pendingNotificationTask: Task<Void, Never>?

    init(
        dependencies: Dependencies,
        shortDebounceNanoseconds: UInt64 = 1_000_000_000,
        bulkDebounceNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.dependencies = dependencies
        self.shortDebounceNanoseconds = shortDebounceNanoseconds
        self.bulkDebounceNanoseconds = bulkDebounceNanoseconds
    }

    /// Queue a coalesced downloadsDidChange notification and refresh dependent UI state first.
    func scheduleDownloadsChanged() {
        pendingNotificationTask?.cancel()
        let dependencies = self.dependencies
        let shortDebounceNanoseconds = self.shortDebounceNanoseconds
        let bulkDebounceNanoseconds = self.bulkDebounceNanoseconds

        pendingNotificationTask = Task { @MainActor [weak self] in
            let pendingCount = await dependencies.fetchPendingDownloadCount()
            let debounceNanoseconds = pendingCount > 3 ? bulkDebounceNanoseconds : shortDebounceNanoseconds
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }

            dependencies.refreshViewContext()
            await dependencies.refreshActiveDownloadRatingKeys()
            dependencies.postDownloadsDidChange()
            self?.pendingNotificationTask = nil
        }
    }

    /// Immediately invalidate UI state for target mutations and cancel any queued debounce.
    func notifyDownloadsChangedImmediately() {
        pendingNotificationTask?.cancel()
        pendingNotificationTask = nil
        dependencies.refreshViewContext()
        dependencies.postDownloadsDidChange()
    }

    /// Surface the queue-finished toast without leaking ToastCenter into the queue coordinator.
    func showQueueCompletionToast() {
        dependencies.showCompletionToast()
    }
}
