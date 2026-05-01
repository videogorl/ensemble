import EnsembleCore
import SwiftUI
import Nuke

#if canImport(UIKit)
import UIKit
private typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
private typealias PlatformImage = NSImage
#endif

public struct ArtworkView: View {
    let path: String?
    let sourceKey: String?
    let ratingKey: String?
    let fallbackPath: String?
    let fallbackRatingKey: String?
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
    /// Tracks the current artwork path so we can clear previousImage when switching
    /// to a different artwork source (prevents stale art from a previous album)
    @State private var currentArtworkPath: String?
    /// Incremented when artwork is invalidated to force a re-load
    @State private var invalidationToken: Int = 0
    
    /// Whether the primary path is missing, so we fall back to fallbackPath/fallbackRatingKey
    private var usesFallback: Bool {
        path == nil || path?.isEmpty == true
    }

    /// Resolved path for cache lookups and load identity
    private var effectivePath: String? {
        usesFallback ? fallbackPath : path
    }

    /// Resolved ratingKey for cache lookups and load identity
    private var effectiveRatingKey: String? {
        usesFallback ? fallbackRatingKey : ratingKey
    }

    /// Unique ID to identify this specific artwork request — avoids string interpolation
    /// by using a stable struct key
    private var loadID: String {
        "\(effectivePath ?? "")|\(effectiveRatingKey ?? "")|\(sourceKey ?? "")|\(size.rawValue)"
    }

    private var imagePriority: ImageRequest.Priority {
        switch size {
        case .tiny:
            return .high
        case .thumbnail, .card, .small:
            return .low
        case .medium, .large, .extraLarge:
            return .normal
        }
    }

    public init(
        path: String?,
        sourceKey: String? = nil,
        ratingKey: String? = nil,
        fallbackPath: String? = nil,
        fallbackRatingKey: String? = nil,
        size: ArtworkSize = .medium,
        cornerRadius: CGFloat? = nil,
        isResponsive: Bool = false
    ) {
        self.path = path
        self.sourceKey = sourceKey
        self.ratingKey = ratingKey
        self.fallbackPath = fallbackPath
        self.fallbackRatingKey = fallbackRatingKey
        self.size = size
        self.cornerRadius = cornerRadius ?? ArtworkCornerRadius.square(for: size)
        self.isResponsive = isResponsive
    }

    public var body: some View {
        // Cache CGSize to avoid recomputing on each access
        let frameSize = size.cgSize
        let iconSize = frameSize.width * 0.3
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

                    artworkContent(iconSize: iconSize)
                        .frame(width: side, height: side)
                        .clipShape(artworkShape)
                        .contentShape(artworkShape)
                }
                .aspectRatio(1, contentMode: .fit)
            } else {
                let artworkShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                artworkContent(iconSize: iconSize)
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
            // Re-trigger load if this artwork's ratingKey was invalidated
            guard let invalidatedKey = notification.userInfo?["ratingKey"] as? String else { return }
            if invalidatedKey == effectiveRatingKey {
                artworkURL = nil
                resolvedImage = nil
                invalidationToken += 1
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ArtworkLoader.serversBecameAvailable)
        ) { _ in
            // Startup Feed cards can begin loading against a stale pre-health-check
            // remote endpoint. When servers become available after failover, retry any
            // unresolved remote URL as well as nil URLs so cards re-resolve against the
            // healthy server without disturbing local file-backed artwork.
            if artworkURL == nil || artworkURL?.isFileURL == false {
                invalidationToken += 1
            }
        }
    }

    @ViewBuilder
    private func artworkContent(iconSize: CGFloat) -> some View {
        ZStack {
            EnsembleDesign.Color.placeholderArtwork

            if let image = resolvedImage {
                platformImageView(image)
            } else if let previousImage {
                // Show the last loaded image during URL transitions to avoid
                // placeholder flash when switching between albums.
                platformImageView(previousImage)
            } else {
                Image(systemName: EnsembleDesign.Icon.musicNote)
                    .font(.system(size: iconSize))
                    .foregroundColor(EnsembleDesign.Color.placeholderArtworkIcon)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private func platformImageView(_ image: PlatformImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #elseif canImport(AppKit)
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    @MainActor
    private func loadArtwork() async {
        let resolvedPath = effectivePath
        let requestedInvalidationToken = invalidationToken

        // Clear stale artwork only when switching to a different artwork source
        // (preserves smooth same-album transitions, prevents showing Album A's
        // art when playing Album B's track that has no artwork).
        if resolvedPath != currentArtworkPath {
            resolvedImage = nil
            previousImage = nil
            currentArtworkPath = resolvedPath
        }

        guard resolvedPath != nil else {
            #if DEBUG
            EnsembleLogger.debug("🎨 ArtworkView[\(size.rawValue)]: No path available - primary:\(path ?? "nil") fallback:\(fallbackPath ?? "nil")")
            #endif
            artworkURL = nil
            resolvedImage = nil
            return
        }

        let url = await dependencies.artworkLoader.artworkURLAsync(
            for: path,
            sourceKey: sourceKey,
            ratingKey: ratingKey,
            fallbackPath: fallbackPath,
            fallbackRatingKey: fallbackRatingKey,
            size: size.rawValue
        )

        if url != artworkURL {
            artworkURL = url
        }

        guard let url else {
            resolvedImage = nil
            return
        }

        // Plex already serves a size-specific transcode for each artwork request, so
        // adding an extra Nuke resize processor here is redundant. Matching the plain
        // request path used by the detail views also avoids a macOS-only Feed failure
        // where uncached remote artwork never resolves into a rendered image.
        let request = ImageRequest(url: url, priority: imagePriority)

        if let cachedImage = ImagePipeline.shared.cache.cachedImage(for: request) {
            guard requestedInvalidationToken == invalidationToken, currentArtworkPath == resolvedPath else { return }
            previousImage = resolvedImage ?? previousImage
            resolvedImage = cachedImage.image
            return
        }

        do {
            let image = try await ImagePipeline.shared.image(for: request)
            guard requestedInvalidationToken == invalidationToken, currentArtworkPath == resolvedPath else { return }
            previousImage = resolvedImage ?? previousImage
            resolvedImage = image
        } catch {
            #if DEBUG
            EnsembleLogger.debug("🎨 ArtworkView[\(size.rawValue)] failed url=\(url.absoluteString) error=\(error.localizedDescription)")
            #endif
        }
    }
}

// MARK: - Convenience Initializers

public extension ArtworkView {
    init(track: Track, size: ArtworkSize = .medium, cornerRadius: CGFloat? = nil, isResponsive: Bool = false) {
        self.init(
            path: track.thumbPath,
            sourceKey: track.sourceCompositeKey,
            ratingKey: track.id,
            fallbackPath: track.fallbackThumbPath,
            fallbackRatingKey: track.fallbackRatingKey,
            size: size,
            cornerRadius: cornerRadius,
            isResponsive: isResponsive
        )
    }

    init(album: Album, size: ArtworkSize = .medium, cornerRadius: CGFloat? = nil, isResponsive: Bool = false) {
        self.init(path: album.thumbPath, sourceKey: album.sourceCompositeKey, ratingKey: album.id, fallbackPath: nil, fallbackRatingKey: nil, size: size, cornerRadius: cornerRadius, isResponsive: isResponsive)
    }

    init(artist: Artist, size: ArtworkSize = .medium, cornerRadius: CGFloat? = nil, isResponsive: Bool = false) {
        self.init(
            path: artist.thumbPath,
            sourceKey: artist.sourceCompositeKey,
            ratingKey: artist.id,
            fallbackPath: artist.fallbackThumbPath,
            fallbackRatingKey: artist.fallbackRatingKey,
            size: size,
            cornerRadius: cornerRadius,
            isResponsive: isResponsive
        )
    }

    init(playlist: Playlist, size: ArtworkSize = .medium, cornerRadius: CGFloat? = nil, isResponsive: Bool = false) {
        self.init(path: playlist.compositePath, sourceKey: playlist.sourceCompositeKey, ratingKey: playlist.id, size: size, cornerRadius: cornerRadius, isResponsive: isResponsive)
    }
}
