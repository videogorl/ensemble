import Foundation

/// Centralizes retry accounting and direct-fallback gating for offline downloads.
/// This keeps transfer policy state out of OfflineDownloadService's queue facade.
@MainActor
final class DownloadRetryPolicy {
    static let maxTransferRetries = 3

    struct DirectFallbackRequest {
        let trackRatingKey: String
        let sourceCompositeKey: String
        let isOffline: Bool
        let canExecuteDownloads: Bool
        let canRunQueueAutomatically: Bool
        let workMode: DownloadWorkMode
    }

    enum DirectFallbackDecision: Equatable {
        case attempt
        case blockedAfterPriorFailure
        case blockedByNetwork
        case blockedWhileSuspended
    }

    struct FailureContext {
        let trackRatingKey: String
        let sourceCompositeKey: String
        let attemptedDirectFallback: Bool
        let updatedQuality: String
        let isCancellation: Bool
        let isNetworkLoss: Bool
        let isRetryableTransfer: Bool
        let errorDescription: String
    }

    enum FailureResolution: Equatable {
        case resetToPending(quality: String)
        case pauseForNetworkLoss
        case retryPending(attempt: Int, maxAttempts: Int, blockDirectFallback: Bool)
        case fail(message: String, blockDirectFallback: Bool)
    }

    private var transferRetryCount: [String: Int] = [:]
    private var blockedDirectFallbackKeys = Set<String>()

    func directFallbackDecision(for request: DirectFallbackRequest) -> DirectFallbackDecision {
        if blockedDirectFallbackKeys.contains(directFallbackKey(trackRatingKey: request.trackRatingKey, sourceCompositeKey: request.sourceCompositeKey)) {
            return .blockedAfterPriorFailure
        }

        if request.isOffline || !request.canExecuteDownloads {
            return .blockedByNetwork
        }

        if !request.canRunQueueAutomatically || request.workMode == .background {
            return .blockedWhileSuspended
        }

        return .attempt
    }

    func resolveFailure(_ context: FailureContext) -> FailureResolution {
        if context.isCancellation {
            return .resetToPending(quality: context.updatedQuality)
        }

        if context.isNetworkLoss {
            return .pauseForNetworkLoss
        }

        if context.isRetryableTransfer {
            let retries = (transferRetryCount[context.trackRatingKey] ?? 0) + 1
            transferRetryCount[context.trackRatingKey] = retries

            if retries <= Self.maxTransferRetries {
                if context.attemptedDirectFallback {
                    blockDirectFallback(trackRatingKey: context.trackRatingKey, sourceCompositeKey: context.sourceCompositeKey)
                }
                return .retryPending(
                    attempt: retries,
                    maxAttempts: Self.maxTransferRetries,
                    blockDirectFallback: context.attemptedDirectFallback
                )
            }

            transferRetryCount.removeValue(forKey: context.trackRatingKey)
            if context.attemptedDirectFallback {
                blockDirectFallback(trackRatingKey: context.trackRatingKey, sourceCompositeKey: context.sourceCompositeKey)
            }
            return .fail(
                message: "Transfer incomplete after \(Self.maxTransferRetries) attempts",
                blockDirectFallback: context.attemptedDirectFallback
            )
        }

        if context.attemptedDirectFallback {
            blockDirectFallback(trackRatingKey: context.trackRatingKey, sourceCompositeKey: context.sourceCompositeKey)
        }
        return .fail(
            message: context.errorDescription,
            blockDirectFallback: context.attemptedDirectFallback
        )
    }

    func recordSuccess(trackRatingKey: String, sourceCompositeKey: String, attemptedDirectFallback: Bool) {
        transferRetryCount.removeValue(forKey: trackRatingKey)
        if attemptedDirectFallback {
            blockedDirectFallbackKeys.remove(
                directFallbackKey(trackRatingKey: trackRatingKey, sourceCompositeKey: sourceCompositeKey)
            )
        }
    }

    private func blockDirectFallback(trackRatingKey: String, sourceCompositeKey: String) {
        blockedDirectFallbackKeys.insert(
            directFallbackKey(trackRatingKey: trackRatingKey, sourceCompositeKey: sourceCompositeKey)
        )
    }

    private func directFallbackKey(trackRatingKey: String, sourceCompositeKey: String) -> String {
        "\(trackRatingKey)|\(sourceCompositeKey)"
    }
}
