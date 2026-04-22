import XCTest
@testable import EnsembleCore

private final class NotificationEventRecorder: @unchecked Sendable {
    private var events: [String] = []

    @MainActor
    func append(_ event: String) {
        events.append(event)
    }

    @MainActor
    func snapshot() -> [String] {
        events
    }
}

@MainActor
final class OfflineDownloadNotificationBridgeTests: XCTestCase {
    func testScheduledNotificationRefreshesStateBeforePosting() async {
        let recorder = NotificationEventRecorder()
        let bridge = OfflineDownloadNotificationBridge(
            dependencies: .init(
                fetchPendingDownloadCount: { 0 },
                refreshActiveDownloadRatingKeys: { await recorder.append("active") },
                refreshViewContext: { recorder.append("refresh") },
                postDownloadsDidChange: { recorder.append("post") },
                showCompletionToast: { recorder.append("toast") }
            ),
            shortDebounceNanoseconds: 1_000_000,
            bulkDebounceNanoseconds: 2_000_000
        )

        bridge.scheduleDownloadsChanged()
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(recorder.snapshot(), ["refresh", "active", "post"])
    }

    func testImmediateNotificationCancelsPendingDebounce() async {
        let recorder = NotificationEventRecorder()
        let bridge = OfflineDownloadNotificationBridge(
            dependencies: .init(
                fetchPendingDownloadCount: { 5 },
                refreshActiveDownloadRatingKeys: { await recorder.append("active") },
                refreshViewContext: { recorder.append("refresh") },
                postDownloadsDidChange: { recorder.append("post") },
                showCompletionToast: { recorder.append("toast") }
            ),
            shortDebounceNanoseconds: 20_000_000,
            bulkDebounceNanoseconds: 20_000_000
        )

        bridge.scheduleDownloadsChanged()
        bridge.notifyDownloadsChangedImmediately()
        try? await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(recorder.snapshot(), ["refresh", "post"])
    }

    func testQueueCompletionToastUsesInjectedHandler() {
        let recorder = NotificationEventRecorder()
        let bridge = OfflineDownloadNotificationBridge(
            dependencies: .init(
                fetchPendingDownloadCount: { 0 },
                refreshActiveDownloadRatingKeys: { await recorder.append("active") },
                refreshViewContext: { recorder.append("refresh") },
                postDownloadsDidChange: { recorder.append("post") },
                showCompletionToast: { recorder.append("toast") }
            )
        )

        bridge.showQueueCompletionToast()

        XCTAssertEqual(recorder.snapshot(), ["toast"])
    }
}
