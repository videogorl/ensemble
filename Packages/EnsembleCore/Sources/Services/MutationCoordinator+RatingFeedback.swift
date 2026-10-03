import Foundation

extension MutationCoordinator {
    public func beginFavoriteUpdate(track: Track, isFavorite: Bool) -> ToastPayload {
        ToastPayload(
            style: .info,
            iconSystemName: "heart.fill",
            title: isFavorite ? "Adding to Favorites..." : "Removing from Favorites...",
            isPersistent: true,
            dedupeKey: "favorite-toggle-loading-\(track.sourceScopedID)",
            showsActivityIndicator: true
        )
    }

    public func finishFavoriteUpdate(
        track: Track,
        isFavorite: Bool,
        outcome: MutationOutcome
    ) -> ToastPayload {
        ToastPayload(
            style: outcome == .queued ? .info : .success,
            iconSystemName: isFavorite ? "heart.fill" : "heart.slash.fill",
            title: outcome == .queued
                ? (isFavorite ? "Saved — will sync when online" : "Removed — will sync when online")
                : (isFavorite ? "Added to Favorites" : "Removed from Favorites"),
            message: track.title,
            dedupeKey: "favorite-toggle-\(outcome == .queued ? "queued" : "success")-\(track.sourceScopedID)-\(isFavorite ? 1 : 0)"
        )
    }

    public func favoriteFailureToast(track: Track, error: Error) -> ToastPayload {
        ToastPayload(
            style: .error,
            iconSystemName: "xmark.octagon.fill",
            title: "Could not update favorite",
            message: error.localizedDescription,
            dedupeKey: "favorite-toggle-error-\(track.sourceScopedID)"
        )
    }

    public func finishRatingUpdate(track: Track, outcome: MutationOutcome) -> ToastPayload? {
        guard outcome == .queued else { return nil }
        return ToastPayload(
            style: .info,
            iconSystemName: "clock.arrow.circlepath",
            title: "Rating saved — will sync when online",
            message: track.title,
            dedupeKey: "rating-toggle-queued-\(track.sourceScopedID)"
        )
    }

    public func ratingFailureToast(track: Track, error: Error) -> ToastPayload {
        ToastPayload(
            style: .error,
            iconSystemName: "xmark.octagon.fill",
            title: "Could not update rating",
            message: error.localizedDescription,
            dedupeKey: "rating-toggle-error-\(track.sourceScopedID)"
        )
    }
}
