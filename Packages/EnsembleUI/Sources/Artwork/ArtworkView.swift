import EnsembleCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct ArtworkView: View {
    let request: ArtworkRequest
    let size: ArtworkSize
    let cornerRadius: CGFloat
    let isResponsive: Bool

    @Environment(\.dependencies) private var dependencies
    @State private var artworkURL: URL?
    /// Snapshot of the currently resolved image.
    @State private var resolvedImage: PlatformImage?
    /// Snapshot of the last successfully loaded image, shown during URL transitions
    /// to prevent placeholder flash when switching albums.
    @State private var previousImage: PlatformImage?
    @State private var currentArtworkIdentity: String?
    /// Incremented when artwork is invalidated to force a re-load
    @State private var invalidationToken: Int = 0
    @State private var serverRetryTask: Task<Void, Never>?
    
    private var loadID: String {
        request.stableBlurCacheKey
    }

    private static func imagePriority(for size: ArtworkSize) -> ArtworkImagePriority {
        switch size {
        case .tiny, .thumbnail, .card, .small:
            return .low
        case .medium, .large, .extraLarge:
            return .normal
        case .detail:
            return .high
        }
    }

    public init(
        path: String?,
        sourceKey: String? = nil,
        ratingKey: String? = nil,
        fallbackPath: String? = nil,
        fallbackRatingKey: String? = nil,
        fallbackSourceKey: String? = nil,
        identity: ArtworkRequest.Identity? = nil,
        fallbackIdentity: ArtworkRequest.Identity? = nil,
        size: ArtworkSize = .medium,
        cornerRadius: CGFloat? = nil,
        isResponsive: Bool = false
    ) {
        self.request = ArtworkRequest(
            path: path,
            sourceKey: sourceKey,
            ratingKey: ratingKey,
            fallbackPath: fallbackPath,
            fallbackRatingKey: fallbackRatingKey,
            fallbackSourceKey: fallbackSourceKey,
            identity: identity,
            fallbackIdentity: fallbackIdentity,
            tier: size.requestTier,
            priority: Self.imagePriority(for: size)
        )
        self.size = size
        self.cornerRadius = cornerRadius ?? ArtworkCornerRadius.square(for: size)
        self.isResponsive = isResponsive
    }

    public var body: some View {
        // Cache CGSize to avoid recomputing on each access
        let frameSize = size.cgSize
        let cornerRadiusRatio = frameSize.width > 0 ? (cornerRadius / frameSize.width) : 0
        let defaultSquareCornerRadius = ArtworkCornerRadius.square(for: size)
        let defaultCircleCornerRadius = ArtworkCornerRadius.circle(for: frameSize.width)
        let shouldScaleCornerRadius =
            abs(cornerRadius - defaultSquareCornerRadius) < 0.5
            || abs(cornerRadius - defaultCircleCornerRadius) < 0.5

        Group {
            if isResponsive {
                GeometryReader { proxy in
                    let side = max(0, proxy.size.width)
                    let responsiveRadius = shouldScaleCornerRadius
                        ? min(max(side * cornerRadiusRatio, 0), side / 2)
                        : min(max(cornerRadius, 0), side / 2)
                    let artworkShape = RoundedRectangle(cornerRadius: responsiveRadius, style: .continuous)

                    artworkContent
                        .frame(width: side, height: side)
                        .clipShape(artworkShape)
                        .contentShape(artworkShape)
                }
                .aspectRatio(1, contentMode: .fit)
            } else {
                let artworkShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                artworkContent
                    .frame(width: frameSize.width, height: frameSize.height)
                    .clipShape(artworkShape)
                    .contentShape(artworkShape)
            }
        }
        .task(id: "\(loadID)|\(invalidationToken)") {
            await loadArtwork()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ArtworkLoader.artworkDidInvalidate)
        ) { notification in
            let invalidatedKeys = notification.userInfo?["ratingKeys"] as? Set<String>
                ?? (notification.userInfo?["ratingKey"] as? String).map { Set([$0]) }
                ?? []
            if !invalidatedKeys.isDisjoint(with: request.ratingKeys) {
                artworkURL = nil
                resolvedImage = nil
                invalidationToken += 1
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ArtworkLoader.serversBecameAvailable)
        ) { _ in
            scheduleServerAvailabilityRetry()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: CacheManager.artworkCachesDidClear)
        ) { _ in
            artworkURL = nil
            resolvedImage = nil
            previousImage = nil
            invalidationToken += 1
        }
        .onDisappear {
            serverRetryTask?.cancel()
            serverRetryTask = nil
        }
    }

    @ViewBuilder
    private var artworkContent: some View {
        ResolvedArtworkImageView(image: resolvedImage ?? previousImage)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @MainActor
    private func loadArtwork() async {
        let requestedInvalidationToken = invalidationToken

        if loadID != currentArtworkIdentity {
            resolvedImage = nil
            previousImage = nil
            currentArtworkIdentity = loadID
        }

        guard request.hasArtwork else {
            artworkURL = nil
            resolvedImage = nil
            return
        }

        let resolved = await dependencies.artworkLoader.resolvedImage(for: request)
        guard requestedInvalidationToken == invalidationToken, currentArtworkIdentity == loadID else { return }
        guard let resolved else {
            artworkURL = nil
            resolvedImage = nil
            return
        }

        if resolved.url != artworkURL {
            artworkURL = resolved.url
        }

        previousImage = resolvedImage ?? previousImage
        resolvedImage = resolved.image
    }

    @MainActor
    private func scheduleServerAvailabilityRetry() {
        guard resolvedImage == nil || artworkURL == nil || artworkURL?.isFileURL == true else { return }

        serverRetryTask?.cancel()
        let jitter = UInt64(abs(loadID.hashValue % 700)) * 1_000_000
        serverRetryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000 + jitter)
            guard !Task.isCancelled else { return }
            let canRetry = await DependencyContainer.shared.foregroundWorkScheduler.waitUntilAllowed(.visibleArtworkRetry, policy: .immediate)
            guard canRetry else {
                serverRetryTask = nil
                return
            }
            guard !Task.isCancelled else { return }
            invalidationToken += 1
            serverRetryTask = nil
        }
    }
}

struct ResolvedArtworkImageView: View {
    let image: PlatformImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                EnsembleDesign.Color.placeholderArtwork
                if let image {
                    platformImage(image)
                } else {
                    Image(systemName: EnsembleDesign.Icon.musicNote)
                        .font(.system(size: min(proxy.size.width, proxy.size.height) * 0.3))
                        .foregroundColor(EnsembleDesign.Color.placeholderArtworkIcon)
                }
            }
        }
    }

    @ViewBuilder
    private func platformImage(_ image: PlatformImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
        #elseif canImport(AppKit)
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
        #endif
    }
}

// MARK: - Convenience Initializers

public extension ArtworkView {
    init(track: Track, size: ArtworkSize = .medium, cornerRadius: CGFloat? = nil, isResponsive: Bool = false) {
        self.request = ArtworkRequest(track: track, tier: size.requestTier, priority: Self.imagePriority(for: size))
        self.size = size
        self.cornerRadius = cornerRadius ?? ArtworkCornerRadius.square(for: size)
        self.isResponsive = isResponsive
    }

    init(album: Album, size: ArtworkSize = .medium, cornerRadius: CGFloat? = nil, isResponsive: Bool = false) {
        self.init(
            path: album.thumbPath,
            sourceKey: album.sourceCompositeKey,
            ratingKey: album.id,
            fallbackPath: nil,
            fallbackRatingKey: nil,
            identity: ArtworkRequest.Identity(album: album),
            size: size,
            cornerRadius: cornerRadius,
            isResponsive: isResponsive
        )
    }

    init(artist: Artist, size: ArtworkSize = .medium, cornerRadius: CGFloat? = nil, isResponsive: Bool = false) {
        self.init(
            path: artist.thumbPath,
            sourceKey: artist.sourceCompositeKey,
            ratingKey: artist.id,
            fallbackPath: artist.fallbackThumbPath,
            fallbackRatingKey: artist.fallbackRatingKey,
            identity: ArtworkRequest.Identity(artist: artist),
            fallbackIdentity: ArtworkRequest.Identity(
                ratingKey: artist.fallbackRatingKey,
                kind: .album,
                sourcePath: artist.fallbackThumbPath
            ),
            size: size,
            cornerRadius: cornerRadius,
            isResponsive: isResponsive
        )
    }

    init(playlist: Playlist, size: ArtworkSize = .medium, cornerRadius: CGFloat? = nil, isResponsive: Bool = false) {
        self.init(
            path: playlist.compositePath,
            sourceKey: playlist.sourceCompositeKey,
            ratingKey: playlist.id,
            fallbackPath: playlist.fallbackArtworkPath,
            fallbackRatingKey: playlist.fallbackArtworkRatingKey,
            fallbackSourceKey: playlist.fallbackArtworkSourceCompositeKey,
            identity: ArtworkRequest.Identity(playlist: playlist),
            fallbackIdentity: ArtworkRequest.Identity(
                ratingKey: playlist.fallbackArtworkRatingKey,
                kind: .album,
                sourcePath: playlist.fallbackArtworkPath,
                sourceCompositeKey: playlist.fallbackArtworkSourceCompositeKey
            ),
            size: size,
            cornerRadius: cornerRadius,
            isResponsive: isResponsive
        )
    }
}
