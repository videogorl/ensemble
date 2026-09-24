import Foundation

@MainActor
public protocol TrackRatingMutationWorkflowMutating: AnyObject {
    @discardableResult
    func rateTrack(_ track: Track, rating: Int?) async throws -> MutationOutcome
}

extension MutationCoordinator: TrackRatingMutationWorkflowMutating {}

public struct TrackRatingMutationWorkflowResult {
    public let outcome: MutationOutcome
    public let toast: ToastPayload?

    public init(outcome: MutationOutcome, toast: ToastPayload?) {
        self.outcome = outcome
        self.toast = toast
    }
}

/// Shared toast and mutation-result policy for favorite/rating changes.
///
/// NowPlayingViewModel keeps immediate optimistic state because it has the playback and local-cache
/// context, while this workflow owns user-facing mutation feedback.
@MainActor
public final class TrackRatingMutationWorkflow {
    private enum Icon {
        static let failure = "xmark.octagon.fill"
        static let favorite = "heart.fill"
        static let queued = "clock.arrow.circlepath"
        static let unfavorite = "heart.slash.fill"
    }

    private let mutator: TrackRatingMutationWorkflowMutating

    public init(mutator: TrackRatingMutationWorkflowMutating) {
        self.mutator = mutator
    }

    @discardableResult
    public func mutate(_ track: Track, rating: Int?) async throws -> MutationOutcome {
        try await mutator.rateTrack(track, rating: rating)
    }

    public func beginFavoriteUpdate(track: Track, isFavorite: Bool) -> ToastPayload {
        let trackIdentity = track.sourceScopedID
        return ToastPayload(
            style: .info,
            iconSystemName: Icon.favorite,
            title: isFavorite ? "Adding to Favorites..." : "Removing from Favorites...",
            isPersistent: true,
            dedupeKey: "favorite-toggle-loading-\(trackIdentity)",
            showsActivityIndicator: true
        )
    }

    public func finishFavoriteUpdate(
        track: Track,
        isFavorite: Bool,
        outcome: MutationOutcome
    ) -> TrackRatingMutationWorkflowResult {
        let trackIdentity = track.sourceScopedID
        if outcome == .queued {
            return TrackRatingMutationWorkflowResult(
                outcome: outcome,
                toast: ToastPayload(
                    style: .info,
                    iconSystemName: isFavorite ? Icon.favorite : Icon.unfavorite,
                    title: isFavorite ? "Saved — will sync when online" : "Removed — will sync when online",
                    message: track.title,
                    dedupeKey: "favorite-toggle-queued-\(trackIdentity)-\(isFavorite ? 1 : 0)"
                )
            )
        }

        return TrackRatingMutationWorkflowResult(
            outcome: outcome,
            toast: ToastPayload(
                style: .success,
                iconSystemName: isFavorite ? Icon.favorite : Icon.unfavorite,
                title: isFavorite ? "Added to Favorites" : "Removed from Favorites",
                message: track.title,
                dedupeKey: "favorite-toggle-success-\(trackIdentity)-\(isFavorite ? 1 : 0)"
            )
        )
    }

    public func favoriteFailureToast(track: Track, error: Error) -> ToastPayload {
        ToastPayload(
            style: .error,
            iconSystemName: Icon.failure,
            title: "Could not update favorite",
            message: error.localizedDescription,
            dedupeKey: "favorite-toggle-error-\(track.sourceScopedID)"
        )
    }

    public func finishRatingUpdate(
        track: Track,
        outcome: MutationOutcome
    ) -> TrackRatingMutationWorkflowResult {
        guard outcome == .queued else {
            return TrackRatingMutationWorkflowResult(outcome: outcome, toast: nil)
        }

        return TrackRatingMutationWorkflowResult(
            outcome: outcome,
            toast: ToastPayload(
                style: .info,
                iconSystemName: Icon.queued,
                title: "Rating saved — will sync when online",
                message: track.title,
                dedupeKey: "rating-toggle-queued-\(track.sourceScopedID)"
            )
        )
    }

    public func ratingFailureToast(track: Track, error: Error) -> ToastPayload {
        ToastPayload(
            style: .error,
            iconSystemName: Icon.failure,
            title: "Could not update rating",
            message: error.localizedDescription,
            dedupeKey: "rating-toggle-error-\(track.sourceScopedID)"
        )
    }
}
