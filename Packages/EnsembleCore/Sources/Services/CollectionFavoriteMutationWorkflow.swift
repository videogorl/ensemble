import CoreData
import EnsemblePersistence
import Foundation

@MainActor
public final class CollectionFavoriteMutationWorkflow {
    private let mutationCoordinator: MutationCoordinator
    private let coreDataStack: CoreDataStack
    private let toastCenter: ToastCenter

    public init(
        mutationCoordinator: MutationCoordinator,
        coreDataStack: CoreDataStack,
        toastCenter: ToastCenter
    ) {
        self.mutationCoordinator = mutationCoordinator
        self.coreDataStack = coreDataStack
        self.toastCenter = toastCenter
    }

    @discardableResult
    public func setFavorite(_ isFavorite: Bool, for album: Album) async throws -> MutationOutcome {
        try await mutate(
            kind: .album,
            ratingKey: album.id,
            sourceCompositeKey: album.sourceCompositeKey,
            title: album.title,
            previousRating: album.rating,
            previousLastRatedAt: album.lastRatedAt,
            isFavorite: isFavorite
        ) {
            try await self.mutationCoordinator.rateAlbum(album, rating: isFavorite ? 10 : nil)
        }
    }

    @discardableResult
    public func setFavorite(_ isFavorite: Bool, for playlist: Playlist) async throws -> MutationOutcome {
        try await mutate(
            kind: .playlist,
            ratingKey: playlist.id,
            sourceCompositeKey: playlist.sourceCompositeKey,
            title: playlist.title,
            previousRating: playlist.rating ?? 0,
            previousLastRatedAt: playlist.lastRatedAt,
            isFavorite: isFavorite
        ) {
            try await self.mutationCoordinator.ratePlaylist(playlist, rating: isFavorite ? 10 : nil)
        }
    }

    private func mutate(
        kind: CollectionRatingKind,
        ratingKey: String,
        sourceCompositeKey: String?,
        title: String,
        previousRating: Int,
        previousLastRatedAt: Date?,
        isFavorite: Bool,
        remoteMutation: () async throws -> MutationOutcome
    ) async throws -> MutationOutcome {
        guard let sourceCompositeKey,
              MediaSourceIdentity.parse(sourceCompositeKey) != nil else {
            throw MusicSourceRoutingError.invalidSourceKey(sourceCompositeKey)
        }

        do {
            try await store(
                kind: kind,
                ratingKey: ratingKey,
                sourceCompositeKey: sourceCompositeKey,
                rating: isFavorite ? 10 : 0,
                lastRatedAt: Date()
            )
            let outcome = try await remoteMutation()
            notifyChange()
            toastCenter.show(successToast(title: title, isFavorite: isFavorite, outcome: outcome))
            return outcome
        } catch {
            try? await store(
                kind: kind,
                ratingKey: ratingKey,
                sourceCompositeKey: sourceCompositeKey,
                rating: previousRating,
                lastRatedAt: previousLastRatedAt
            )
            notifyChange()
            toastCenter.show(ToastPayload(
                style: .error,
                iconSystemName: "xmark.octagon.fill",
                title: "Could not update favorite",
                message: error.localizedDescription,
                dedupeKey: "collection-favorite-error-\(sourceCompositeKey)-\(ratingKey)"
            ))
            throw error
        }
    }

    private func store(
        kind: CollectionRatingKind,
        ratingKey: String,
        sourceCompositeKey: String,
        rating: Int,
        lastRatedAt: Date?
    ) async throws {
        try await coreDataStack.performBackgroundContext { context in
            switch kind {
            case .album:
                let request = CDAlbum.fetchRequest()
                request.predicate = NSPredicate(
                    format: "ratingKey == %@ AND sourceCompositeKey == %@",
                    ratingKey,
                    sourceCompositeKey
                )
                if let album = try context.fetch(request).first {
                    album.rating = Int16(rating)
                    album.lastRatedAt = lastRatedAt
                }
            case .playlist:
                let request = CDPlaylist.fetchRequest()
                request.predicate = NSPredicate(
                    format: "ratingKey == %@ AND sourceCompositeKey == %@",
                    ratingKey,
                    sourceCompositeKey
                )
                if let playlist = try context.fetch(request).first {
                    playlist.rating = Int16(rating)
                    playlist.lastRatedAt = lastRatedAt
                }
            }
            if context.hasChanges {
                try context.save()
            }
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: MetadataMutationService.metadataDidChange, object: nil)
    }

    private func successToast(
        title: String,
        isFavorite: Bool,
        outcome: MutationOutcome
    ) -> ToastPayload {
        ToastPayload(
            style: outcome == .queued ? .info : .success,
            iconSystemName: isFavorite ? "heart.fill" : "heart.slash.fill",
            title: outcome == .queued
                ? (isFavorite ? "Saved — will sync when online" : "Removed — will sync when online")
                : (isFavorite ? "Added to Favorites" : "Removed from Favorites"),
            message: title
        )
    }
}
