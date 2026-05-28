import EnsembleCore
import Foundation
import Nuke

struct ArtworkResolutionDescriptor {
    let path: String?
    let sourceKey: String?
    let ratingKey: String?
    let fallbackPath: String?
    let fallbackRatingKey: String?
    let cacheHint: PersistentArtworkCacheHint?
    let fallbackCacheHint: PersistentArtworkCacheHint?
    let size: Int
    let priority: ImageRequest.Priority

    var effectiveCacheHint: PersistentArtworkCacheHint? {
        if let path, !path.isEmpty {
            return cacheHint
        }
        return fallbackCacheHint
    }
}

struct ArtworkResolvedImage {
    let url: URL
    let image: PlatformImage
}

enum ArtworkImageResolver {
    static func resolvedImage(
        for descriptor: ArtworkResolutionDescriptor,
        artworkLoader: ArtworkLoaderProtocol
    ) async -> ArtworkResolvedImage? {
        guard let url = await artworkLoader.artworkURLAsync(
            for: descriptor.path,
            sourceKey: descriptor.sourceKey,
            ratingKey: descriptor.ratingKey,
            fallbackPath: descriptor.fallbackPath,
            fallbackRatingKey: descriptor.fallbackRatingKey,
            size: descriptor.size
        ) else {
            return nil
        }

        let request = ArtworkImageRequest.resized(url: url, size: descriptor.size, priority: descriptor.priority)
        if let cachedImage = ImagePipeline.shared.cache.cachedImage(for: request) {
            await artworkLoader.cacheResolvedArtwork(from: url, cacheHint: descriptor.effectiveCacheHint)
            return ArtworkResolvedImage(url: url, image: cachedImage.image)
        }

        guard let image = try? await ImagePipeline.shared.image(for: request) else {
            return nil
        }
        await artworkLoader.cacheResolvedArtwork(from: url, cacheHint: descriptor.effectiveCacheHint)
        return ArtworkResolvedImage(url: url, image: image)
    }

    static func preBlurredImage(
        for image: PlatformImage?,
        scheduler: ForegroundWorkScheduling = DependencyContainer.shared.foregroundWorkScheduler,
        requiresIdle: Bool = true
    ) async -> PlatformImage? {
        guard let image else { return nil }
        if let cached = ArtworkBlurRenderer.cachedBlurredImage(for: image) {
            return cached
        }

        if requiresIdle {
            guard await scheduler.waitUntilAllowed(.artworkRetry, policy: .idleOnly) else {
                return nil
            }
        }

        let sendableImage = SendableArtworkPlatformImage(image)
        let blurred = await Task.detached(priority: .utility) {
            ArtworkBlurRenderer.blurredImage(from: sendableImage.value)
                .map(SendableArtworkPlatformImage.init)
        }.value
        return blurred?.value
    }
}

private struct SendableArtworkPlatformImage: @unchecked Sendable {
    let value: PlatformImage

    init(_ value: PlatformImage) {
        self.value = value
    }
}
