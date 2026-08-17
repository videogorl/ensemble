import Foundation
import Nuke

public enum ArtworkImagePriority: Sendable {
    case low
    case normal
    case high
}

public struct ArtworkResolutionDescriptor: Sendable {
    public let path: String?
    public let sourceKey: String?
    public let ratingKey: String?
    public let fallbackPath: String?
    public let fallbackRatingKey: String?
    public let fallbackSourceKey: String?
    public let cacheHint: PersistentArtworkCacheHint?
    public let fallbackCacheHint: PersistentArtworkCacheHint?
    public let size: Int
    public let priority: ArtworkImagePriority

    public init(
        path: String?,
        sourceKey: String?,
        ratingKey: String?,
        fallbackPath: String?,
        fallbackRatingKey: String?,
        fallbackSourceKey: String? = nil,
        cacheHint: PersistentArtworkCacheHint?,
        fallbackCacheHint: PersistentArtworkCacheHint?,
        size: Int,
        priority: ArtworkImagePriority
    ) {
        self.path = path
        self.sourceKey = sourceKey
        self.ratingKey = ratingKey
        self.fallbackPath = fallbackPath
        self.fallbackRatingKey = fallbackRatingKey
        self.fallbackSourceKey = fallbackSourceKey
        self.cacheHint = cacheHint
        self.fallbackCacheHint = fallbackCacheHint
        self.size = size
        self.priority = priority
    }

    public init(
        track: Track,
        fallbackSourceKey: String? = nil,
        size: Int,
        priority: ArtworkImagePriority
    ) {
        let sourceKey = track.sourceCompositeKey ?? fallbackSourceKey
        let albumRatingKey = track.fallbackRatingKey ?? track.albumRatingKey
        self.init(
            path: track.thumbPath,
            sourceKey: sourceKey,
            ratingKey: track.id,
            fallbackPath: track.fallbackThumbPath,
            fallbackRatingKey: albumRatingKey,
            cacheHint: nil,
            fallbackCacheHint: PersistentArtworkCacheHint(
                ratingKey: albumRatingKey,
                kind: .album,
                sourcePath: track.fallbackThumbPath,
                sourceCompositeKey: sourceKey
            ),
            size: size,
            priority: priority
        )
    }

    var effectiveCacheHint: PersistentArtworkCacheHint? {
        if let path, !path.isEmpty {
            return cacheHint
        }
        return fallbackCacheHint
    }

    private var effectiveSourceKey: String? {
        if let path, !path.isEmpty {
            return sourceKey
        }
        return fallbackSourceKey ?? fallbackCacheHint?.sourceCompositeKey ?? sourceKey
    }

    public var stableBlurCacheKey: String {
        if let cacheHint = effectiveCacheHint {
            return [
                "hint",
                cacheHint.sourceCompositeKey ?? effectiveSourceKey ?? "no-source",
                cacheHint.kind.rawValue,
                cacheHint.ratingKey,
                cacheHint.sourcePath,
                cacheHint.dateModifiedSeconds.map(String.init) ?? "no-date",
                String(size)
            ].joined(separator: "|")
        }

        return [
            "descriptor",
            effectiveSourceKey ?? "no-source",
            ratingKey ?? "no-rating",
            path ?? "no-path",
            fallbackRatingKey ?? "no-fallback-rating",
            fallbackPath ?? "no-fallback-path",
            String(size)
        ].joined(separator: "|")
    }
}

public struct ArtworkResolvedImage: Sendable {
    public let url: URL
    public let image: PlatformImage
    public let blurCacheKey: String
}

public enum ArtworkImageResolutionOutcome: Sendable {
    case resolved(ArtworkResolvedImage)
    case unavailable(ArtworkImageResolutionUnavailableReason)
}

public enum ArtworkImageResolutionUnavailableReason: Sendable, Equatable {
    case noArtworkURL
    case imageLoadFailed(URL)
}

public enum ArtworkImageResolver {
    public static func locallyCachedImage(
        for descriptor: ArtworkResolutionDescriptor,
        artworkLoader: ArtworkLoaderProtocol
    ) async -> ArtworkResolvedImage? {
        for candidate in candidateDescriptors(for: descriptor) {
            guard let localURL = await artworkLoader.localArtworkURLAsync(
                for: candidate.path,
                sourceKey: candidate.sourceKey,
                ratingKey: candidate.ratingKey,
                fallbackPath: nil,
                fallbackRatingKey: nil,
                minimumPixelDimension: candidate.size,
                allowStaleIdentity: true
            ),
                  let resolved = await image(for: localURL, descriptor: candidate) else {
                continue
            }
            return resolved
        }
        return nil
    }

    public static func resolvedImage(
        for descriptor: ArtworkResolutionDescriptor,
        artworkLoader: ArtworkLoaderProtocol
    ) async -> ArtworkResolvedImage? {
        guard case .resolved(let image) = await resolveImage(for: descriptor, artworkLoader: artworkLoader) else {
            return nil
        }
        return image
    }

    public static func resolveImage(
        for descriptor: ArtworkResolutionDescriptor,
        artworkLoader: ArtworkLoaderProtocol
    ) async -> ArtworkImageResolutionOutcome {
        let candidates = candidateDescriptors(for: descriptor)
        var failedURL: URL?

        if let local = await locallyCachedImage(
            for: descriptor,
            artworkLoader: artworkLoader
        ) {
            return .resolved(local)
        }

        for candidate in candidates {
            let url = await artworkLoader.artworkURLAsync(
                for: candidate.path,
                sourceKey: candidate.sourceKey,
                ratingKey: candidate.ratingKey,
                fallbackPath: nil,
                fallbackRatingKey: nil,
                size: candidate.size
            )

            if let url,
               let resolved = await image(for: url, descriptor: candidate) {
                await artworkLoader.cacheResolvedArtwork(
                    from: url,
                    cacheHint: candidate.cacheHint?.scoped(to: candidate.sourceKey),
                    minimumPixelDimension: candidate.size
                )
                return .resolved(resolved)
            }

            if let url {
                failedURL = url
            }
            if let local = await resolvedLocalImage(
                for: candidate,
                failedURL: url,
                artworkLoader: artworkLoader
            ) {
                return .resolved(local)
            }
        }

        if let failedURL {
            return .unavailable(.imageLoadFailed(failedURL))
        }
        return .unavailable(.noArtworkURL)
    }

    public static func preBlurredImage(
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

    private static func candidateDescriptors(
        for descriptor: ArtworkResolutionDescriptor
    ) -> [ArtworkResolutionDescriptor] {
        var candidates: [ArtworkResolutionDescriptor] = []
        if descriptor.path?.isEmpty == false {
            candidates.append(ArtworkResolutionDescriptor(
                path: descriptor.path,
                sourceKey: descriptor.sourceKey,
                ratingKey: descriptor.ratingKey,
                fallbackPath: nil,
                fallbackRatingKey: nil,
                cacheHint: descriptor.cacheHint,
                fallbackCacheHint: nil,
                size: descriptor.size,
                priority: descriptor.priority
            ))
        }
        if descriptor.fallbackPath?.isEmpty == false {
            let fallback = ArtworkResolutionDescriptor(
                path: descriptor.fallbackPath,
                sourceKey: descriptor.fallbackSourceKey
                    ?? descriptor.fallbackCacheHint?.sourceCompositeKey
                    ?? descriptor.sourceKey,
                ratingKey: descriptor.fallbackRatingKey,
                fallbackPath: nil,
                fallbackRatingKey: nil,
                cacheHint: descriptor.fallbackCacheHint,
                fallbackCacheHint: nil,
                size: descriptor.size,
                priority: descriptor.priority
            )
            if fallback.stableBlurCacheKey != candidates.first?.stableBlurCacheKey {
                candidates.append(fallback)
            }
        }
        return candidates
    }

    private static func resolvedLocalImage(
        for descriptor: ArtworkResolutionDescriptor,
        failedURL: URL?,
        artworkLoader: ArtworkLoaderProtocol
    ) async -> ArtworkResolvedImage? {
        guard let localURL = await artworkLoader.localArtworkURLAsync(
            for: descriptor.path,
            sourceKey: descriptor.sourceKey,
            ratingKey: descriptor.ratingKey,
            fallbackPath: nil,
            fallbackRatingKey: nil,
            minimumPixelDimension: nil,
            allowStaleIdentity: true
        ),
              localURL != failedURL else {
            return nil
        }

        return await image(for: localURL, descriptor: descriptor)
    }

    private static func image(
        for url: URL,
        descriptor: ArtworkResolutionDescriptor
    ) async -> ArtworkResolvedImage? {
        let request = ArtworkImageRequest.resized(
            url: url,
            size: descriptor.size,
            priority: descriptor.priority.nukePriority
        )

        if let cachedImage = ImagePipeline.shared.cache.cachedImage(for: request) {
            return ArtworkResolvedImage(
                url: url,
                image: cachedImage.image,
                blurCacheKey: descriptor.stableBlurCacheKey
            )
        }

        guard let image = try? await ImagePipeline.shared.image(for: request) else {
            return nil
        }

        return ArtworkResolvedImage(
            url: url,
            image: image,
            blurCacheKey: descriptor.stableBlurCacheKey
        )
    }
}

private struct SendableArtworkPlatformImage: @unchecked Sendable {
    let value: PlatformImage

    init(_ value: PlatformImage) {
        self.value = value
    }
}

enum ArtworkImageRequest {
    static func resized(
        url: URL,
        size: Int,
        priority: ImageRequest.Priority = .normal
    ) -> ImageRequest {
        resized(
            url: url,
            size: CGSize(width: size, height: size),
            priority: priority
        )
    }

    static func resized(
        url: URL,
        size: CGSize,
        priority: ImageRequest.Priority = .normal
    ) -> ImageRequest {
        ImageRequest(
            url: url,
            processors: [
                ImageProcessors.Resize(
                    size: size,
                    contentMode: .aspectFill,
                    upscale: false
                )
            ],
            priority: priority
        )
    }
}

private extension ArtworkImagePriority {
    var nukePriority: ImageRequest.Priority {
        switch self {
        case .low:
            return .low
        case .normal:
            return .normal
        case .high:
            return .high
        }
    }
}
