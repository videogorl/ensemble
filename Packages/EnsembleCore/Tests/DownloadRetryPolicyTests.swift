import XCTest
@testable import EnsembleCore

@MainActor
final class DownloadRetryPolicyTests: XCTestCase {
    func testDirectFallbackDecisionBlocksPriorFailureInSession() {
        let policy = DownloadRetryPolicy()

        _ = policy.resolveFailure(
            .init(
                trackRatingKey: "track",
                sourceCompositeKey: "source",
                attemptedDirectFallback: true,
                isNetworkLoss: false,
                isRetryableTransfer: false,
                errorDescription: "boom"
            )
        )

        let decision = policy.directFallbackDecision(
            for: .init(
                trackRatingKey: "track",
                sourceCompositeKey: "source",
                isOffline: false,
                canExecuteDownloads: true,
                canRunQueueAutomatically: true,
                workMode: .foregroundIdle
            )
        )

        XCTAssertEqual(decision, .blockedAfterPriorFailure)
    }

    func testDirectFallbackDecisionBlocksNetworkAndSuspendedStates() {
        let policy = DownloadRetryPolicy()

        XCTAssertEqual(
            policy.directFallbackDecision(
                for: .init(
                    trackRatingKey: "track",
                    sourceCompositeKey: "source",
                    isOffline: true,
                    canExecuteDownloads: false,
                    canRunQueueAutomatically: true,
                    workMode: .foregroundIdle
                )
            ),
            .blockedByNetwork
        )

        XCTAssertEqual(
            policy.directFallbackDecision(
                for: .init(
                    trackRatingKey: "track-2",
                    sourceCompositeKey: "source",
                    isOffline: false,
                    canExecuteDownloads: true,
                    canRunQueueAutomatically: false,
                    workMode: .background
                )
            ),
            .blockedWhileSuspended
        )
    }

    func testRetryableTransferRetriesThenFailsAtCap() {
        let policy = DownloadRetryPolicy()

        let first = policy.resolveFailure(
            .init(
                trackRatingKey: "track",
                sourceCompositeKey: "source",
                attemptedDirectFallback: true,
                isNetworkLoss: false,
                isRetryableTransfer: true,
                errorDescription: "short read"
            )
        )
        XCTAssertEqual(first, .retryPending(attempt: 1, maxAttempts: 3, blockDirectFallback: true))

        _ = policy.resolveFailure(
            .init(
                trackRatingKey: "track",
                sourceCompositeKey: "source",
                attemptedDirectFallback: true,
                isNetworkLoss: false,
                isRetryableTransfer: true,
                errorDescription: "short read"
            )
        )
        _ = policy.resolveFailure(
            .init(
                trackRatingKey: "track",
                sourceCompositeKey: "source",
                attemptedDirectFallback: true,
                isNetworkLoss: false,
                isRetryableTransfer: true,
                errorDescription: "short read"
            )
        )

        let fourth = policy.resolveFailure(
            .init(
                trackRatingKey: "track",
                sourceCompositeKey: "source",
                attemptedDirectFallback: true,
                isNetworkLoss: false,
                isRetryableTransfer: true,
                errorDescription: "short read"
            )
        )

        XCTAssertEqual(
            fourth,
            .fail(message: "Transfer incomplete after 3 attempts", blockDirectFallback: true)
        )
    }

    func testRetryableTransferRetriesAreSourceScoped() {
        let policy = DownloadRetryPolicy()

        for _ in 0..<DownloadRetryPolicy.maxTransferRetries {
            _ = policy.resolveFailure(
                .init(
                    trackRatingKey: "shared-rating-key",
                    sourceCompositeKey: "source-a",
                    attemptedDirectFallback: false,
                    isNetworkLoss: false,
                    isRetryableTransfer: true,
                    errorDescription: "short read"
                )
            )
        }

        let otherSourceFirstFailure = policy.resolveFailure(
            .init(
                trackRatingKey: "shared-rating-key",
                sourceCompositeKey: "source-b",
                attemptedDirectFallback: false,
                isNetworkLoss: false,
                isRetryableTransfer: true,
                errorDescription: "short read"
            )
        )

        XCTAssertEqual(
            otherSourceFirstFailure,
            .retryPending(attempt: 1, maxAttempts: 3, blockDirectFallback: false)
        )
    }

    func testNetworkLossPausesWithoutConsumingTransferRetry() {
        let policy = DownloadRetryPolicy()

        XCTAssertEqual(
            policy.resolveFailure(
                .init(
                    trackRatingKey: "track",
                    sourceCompositeKey: "source",
                    attemptedDirectFallback: false,
                    isNetworkLoss: true,
                    isRetryableTransfer: false,
                    errorDescription: "offline"
                )
            ),
            .pauseForNetworkLoss
        )
    }

    func testRecordSuccessClearsRetryCountersAndFallbackBlock() {
        let policy = DownloadRetryPolicy()

        _ = policy.resolveFailure(
            .init(
                trackRatingKey: "track",
                sourceCompositeKey: "source",
                attemptedDirectFallback: true,
                isNetworkLoss: false,
                isRetryableTransfer: true,
                errorDescription: "short read"
            )
        )

        policy.recordSuccess(trackRatingKey: "track", sourceCompositeKey: "source", attemptedDirectFallback: true)

        let decision = policy.directFallbackDecision(
            for: .init(
                trackRatingKey: "track",
                sourceCompositeKey: "source",
                isOffline: false,
                canExecuteDownloads: true,
                canRunQueueAutomatically: true,
                workMode: .foregroundIdle
            )
        )

        XCTAssertEqual(decision, .attempt)
    }
}
