import EnsembleCore

enum TrackArtworkThumbnailLoader {
    static func cachedImage(
        for track: Track,
        artworkLoader: ArtworkLoaderProtocol
    ) -> PlatformImage? {
        artworkLoader.synchronouslyCachedImage(for: request(for: track))?.image
    }

    @MainActor
    static func image(
        for track: Track,
        artworkLoader: ArtworkLoaderProtocol,
        isCurrent: () -> Bool
    ) async -> PlatformImage? {
        guard isCurrent() else {
            return nil
        }

        let request = request(for: track)

        if let image = artworkLoader.synchronouslyCachedImage(for: request)?.image {
            return image
        }

        let resolved = await artworkLoader.resolvedImage(for: request)
        return isCurrent() ? resolved?.image : nil
    }

    private static func request(for track: Track) -> ArtworkRequest {
        ArtworkRequest(track: track, tier: .thumbnail, priority: .low)
    }
}
