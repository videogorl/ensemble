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

/// Loads track thumbnails into one reusable table cell.
///
/// Each load takes a new generation; a load that finishes after the cell
/// moved on (reuse, another track, artwork hidden) sees a newer generation
/// and is dropped. Redrawing the track already shown requests nothing.
@MainActor
final class TrackCellArtwork {
    private var generation: UInt = 0
    private var task: Task<Void, Never>?
    private var trackIdentity: String?

    /// Shows `track`'s thumbnail through `setImage`: a cached image at once,
    /// otherwise nil and then the loaded image.
    func show(
        _ track: Track,
        artworkLoader: ArtworkLoaderProtocol,
        setImage: @escaping (PlatformImage?) -> Void
    ) {
        let identity = track.playbackIdentity
        guard identity != trackIdentity else { return }
        reset()
        trackIdentity = identity

        let cached = TrackArtworkThumbnailLoader.cachedImage(for: track, artworkLoader: artworkLoader)
        setImage(cached)
        guard cached == nil else { return }

        let expected = generation
        task = Task { [weak self] in
            let image = await TrackArtworkThumbnailLoader.image(for: track, artworkLoader: artworkLoader) {
                self?.generation == expected
            }
            if self?.generation == expected {
                setImage(image)
            }
        }
    }

    /// Drops any load in flight and forgets the track.
    func reset() {
        generation &+= 1
        task?.cancel()
        task = nil
        trackIdentity = nil
    }

    /// Forgets a track whose thumbnail never arrived, so the next `show`
    /// loads it again. False when the cell already has an image.
    func prepareRetry(hasImage: Bool) -> Bool {
        guard !hasImage else { return false }
        trackIdentity = nil
        return true
    }
}
