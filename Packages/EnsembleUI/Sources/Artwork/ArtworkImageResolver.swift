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

    var stableBlurCacheKey: String {
        if let cacheHint = effectiveCacheHint {
            return [
                "hint",
                cacheHint.kind.rawValue,
                cacheHint.ratingKey,
                cacheHint.sourcePath,
                cacheHint.dateModifiedSeconds.map(String.init) ?? "no-date",
                String(size)
            ].joined(separator: "|")
        }

        return [
            "descriptor",
            sourceKey ?? "no-source",
            ratingKey ?? "no-rating",
            path ?? "no-path",
            fallbackRatingKey ?? "no-fallback-rating",
            fallbackPath ?? "no-fallback-path",
            String(size)
        ].joined(separator: "|")
    }
}

struct ArtworkResolvedImage {
    let url: URL
    let image: PlatformImage
    let blurCacheKey: String
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
            await artworkLoader.cacheResolvedArtwork(
                from: url,
                cacheHint: descriptor.effectiveCacheHint,
                minimumPixelDimension: descriptor.size
            )
            return ArtworkResolvedImage(
                url: url,
                image: cachedImage.image,
                blurCacheKey: descriptor.stableBlurCacheKey
            )
        }

        guard let image = try? await ImagePipeline.shared.image(for: request) else {
            return nil
        }
        await artworkLoader.cacheResolvedArtwork(
            from: url,
            cacheHint: descriptor.effectiveCacheHint,
            minimumPixelDimension: descriptor.size
        )
        return ArtworkResolvedImage(
            url: url,
            image: image,
            blurCacheKey: descriptor.stableBlurCacheKey
        )
    }

    static func preBlurredImage(
        for image: PlatformImage?,
        cacheKey: String? = nil,
        scheduler: ForegroundWorkScheduling = DependencyContainer.shared.foregroundWorkScheduler,
        requiresIdle: Bool = false
    ) async -> PlatformImage? {
        guard let image else { return nil }
        if let cacheKey,
           let cached = ArtworkBlurRenderer.cachedBlurredImage(forStableKey: cacheKey) {
            return cached
        }
        if let cached = ArtworkBlurRenderer.cachedBlurredImage(for: image) {
            return cached
        }

        if requiresIdle {
            guard await scheduler.waitUntilAllowed(.artworkRetry, policy: .idleOnly) else {
                return nil
            }
        } else {
            guard await scheduler.waitUntilAllowed(.visibleArtworkRetry, policy: .immediate) else {
                return nil
            }
        }

        let sendableImage = SendableArtworkPlatformImage(image)
        let stableCacheKey = cacheKey
        let blurred = await Task.detached(priority: .utility) {
            ArtworkBlurRenderer.blurredImage(from: sendableImage.value, stableKey: stableCacheKey)
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
