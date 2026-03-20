import EnsembleCore
import SwiftUI
import Nuke
import NukeUI

public struct ArtworkView: View {
    let path: String?
    let sourceKey: String?
    let ratingKey: String?
    let fallbackPath: String?
    let fallbackRatingKey: String?
    let size: ArtworkSize
    let cornerRadius: CGFloat

    @Environment(\.dependencies) private var dependencies
    @State private var artworkURL: URL?
    /// Snapshot of the last successfully loaded image, shown during URL transitions
    /// to prevent placeholder flash when switching albums
    @State private var previousImage: Image?
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
        case .thumbnail, .small:
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
        cornerRadius: CGFloat = 8
    ) {
        self.path = path
        self.sourceKey = sourceKey
        self.ratingKey = ratingKey
        self.fallbackPath = fallbackPath
        self.fallbackRatingKey = fallbackRatingKey
        self.size = size
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        // Cache CGSize to avoid recomputing on each access
        let frameSize = size.cgSize
        let iconSize = frameSize.width * 0.3

        LazyImage(url: artworkURL) { state in
            ZStack {
                Color.gray.opacity(0.2)

                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .onAppear {
                            // Capture successful loads so we can show them during transitions
                            previousImage = state.image
                        }
                } else if let previous = previousImage {
                    // Show the last loaded image during URL transitions to avoid
                    // placeholder flash when switching between albums
                    previous
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if state.error != nil {
                    Image(systemName: "music.note")
                        .font(.system(size: iconSize))
                        .foregroundColor(.gray.opacity(0.5))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: iconSize))
                        .foregroundColor(.gray.opacity(0.5))
                }
            }
        }
        .processors([.resize(size: frameSize, contentMode: .aspectFill, upscale: true)])
        .priority(imagePriority)
        .aspectRatio(1, contentMode: .fill)
        .frame(maxWidth: frameSize.width, maxHeight: frameSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: "\(loadID)|\(invalidationToken)") {
            await loadArtworkURL()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ArtworkLoader.artworkDidInvalidate)
        ) { notification in
            // Re-trigger load if this artwork's ratingKey was invalidated
            guard let invalidatedKey = notification.userInfo?["ratingKey"] as? String else { return }
            if invalidatedKey == effectiveRatingKey {
                artworkURL = nil
                invalidationToken += 1
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ArtworkLoader.serversBecameAvailable)
        ) { _ in
            // With local-first artwork, file URLs are the norm.
            // Only retry when we have NO artwork at all (nil URL means no local cache existed).
            if artworkURL == nil {
                invalidationToken += 1
            }
        }
    }
    
    private func loadArtworkURL() async {
        let resolvedPath = effectivePath

        // Clear stale artwork only when switching to a different artwork source
        // (preserves smooth same-album transitions, prevents showing Album A's
        // art when playing Album B's track that has no artwork)
        if resolvedPath != currentArtworkPath {
            previousImage = nil
            currentArtworkPath = resolvedPath
        }

        guard resolvedPath != nil else {
            #if DEBUG
            EnsembleLogger.debug("🎨 ArtworkView[\(size.rawValue)]: No path available - primary:\(path ?? "nil") fallback:\(fallbackPath ?? "nil")")
            #endif
            artworkURL = nil
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
    }
}

// MARK: - Convenience Initializers

public extension ArtworkView {
    init(track: Track, size: ArtworkSize = .medium, cornerRadius: CGFloat = 8) {
        self.init(
            path: track.thumbPath,
            sourceKey: track.sourceCompositeKey,
            ratingKey: track.id,
            fallbackPath: track.fallbackThumbPath,
            fallbackRatingKey: track.fallbackRatingKey,
            size: size,
            cornerRadius: cornerRadius
        )
    }

    init(album: Album, size: ArtworkSize = .medium, cornerRadius: CGFloat = 8) {
        self.init(path: album.thumbPath, sourceKey: album.sourceCompositeKey, ratingKey: album.id, size: size, cornerRadius: cornerRadius)
    }

    init(artist: Artist, size: ArtworkSize = .medium, cornerRadius: CGFloat = 8) {
        self.init(
            path: artist.thumbPath,
            sourceKey: artist.sourceCompositeKey,
            ratingKey: artist.id,
            fallbackPath: artist.fallbackThumbPath,
            fallbackRatingKey: artist.fallbackRatingKey,
            size: size,
            cornerRadius: cornerRadius
        )
    }

    init(playlist: Playlist, size: ArtworkSize = .medium, cornerRadius: CGFloat = 8) {
        self.init(path: playlist.compositePath, sourceKey: playlist.sourceCompositeKey, ratingKey: playlist.id, size: size, cornerRadius: cornerRadius)
    }
}
