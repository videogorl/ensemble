import EnsembleCore
import Nuke

enum TrackArtworkThumbnailLoader {
    @MainActor
    static func image(
        for track: Track,
        artworkLoader: ArtworkLoaderProtocol,
        isCurrent: () -> Bool
    ) async -> PlatformImage? {
        guard isCurrent(),
              let url = await artworkLoader.artworkURLAsync(
                for: track.thumbPath,
                sourceKey: track.sourceCompositeKey,
                ratingKey: track.id,
                fallbackPath: track.fallbackThumbPath,
                fallbackRatingKey: track.fallbackRatingKey,
                size: ArtworkSize.thumbnail.rawValue
              ),
              isCurrent()
        else {
            return nil
        }

        let request = ArtworkImageRequest.resized(
            url: url,
            size: ArtworkSize.thumbnail.rawValue,
            priority: .high
        )

        if let cachedImage = ImagePipeline.shared.cache.cachedImage(for: request) {
            return isCurrent() ? cachedImage.image : nil
        }

        guard let image = try? await ImagePipeline.shared.image(for: request) else {
            return nil
        }
        return isCurrent() ? image : nil
    }
}
