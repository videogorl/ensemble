import EnsembleCore

enum TrackArtworkThumbnailLoader {
    @MainActor
    static func image(
        for track: Track,
        artworkLoader: ArtworkLoaderProtocol,
        isCurrent: () -> Bool
    ) async -> PlatformImage? {
        guard isCurrent() else {
            return nil
        }

        let descriptor = ArtworkResolutionDescriptor(
            path: track.thumbPath,
            sourceKey: track.sourceCompositeKey,
            ratingKey: track.id,
            fallbackPath: track.fallbackThumbPath,
            fallbackRatingKey: track.fallbackRatingKey,
            cacheHint: nil,
            fallbackCacheHint: PersistentArtworkCacheHint(fallbackAlbumArtworkFor: track),
            size: ArtworkSize.thumbnail.rawValue,
            priority: .high
        )

        let resolved = await ArtworkImageResolver.resolvedImage(for: descriptor, artworkLoader: artworkLoader)
        return isCurrent() ? resolved?.image : nil
    }
}
