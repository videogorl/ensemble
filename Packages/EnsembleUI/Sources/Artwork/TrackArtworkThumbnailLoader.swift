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
            track: track,
            size: ArtworkSize.thumbnail.requestPixelDimension,
            priority: .low
        )

        let resolved = await ArtworkImageResolver.resolvedImage(for: descriptor, artworkLoader: artworkLoader)
        return isCurrent() ? resolved?.image : nil
    }
}
