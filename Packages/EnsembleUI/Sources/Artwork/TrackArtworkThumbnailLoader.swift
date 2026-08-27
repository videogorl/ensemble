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

        let request = ArtworkRequest(
            track: track,
            tier: .thumbnail,
            priority: .low
        )

        let resolved = await artworkLoader.resolvedImage(for: request)
        return isCurrent() ? resolved?.image : nil
    }
}
