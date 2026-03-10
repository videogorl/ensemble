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
    /// Incremented when artwork is invalidated to force a re-load
    @State private var invalidationToken: Int = 0
    
    // Unique ID to identify this specific artwork request
    private var loadID: String {
        let actualPath = (path == nil || path?.isEmpty == true) ? fallbackPath : path
        let actualRatingKey = (path == nil || path?.isEmpty == true) ? fallbackRatingKey : ratingKey
        return "\(actualPath ?? "")|\(actualRatingKey ?? "")|\(sourceKey ?? "")|\(size.rawValue)"
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
        LazyImage(url: artworkURL) { state in
            ZStack {
                Color.gray.opacity(0.2)
                
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if state.error != nil {
                    Image(systemName: "music.note")
                        .font(.system(size: size.cgSize.width * 0.3))
                        .foregroundColor(.gray.opacity(0.5))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: size.cgSize.width * 0.3))
                        .foregroundColor(.gray.opacity(0.5))
                }
            }
        }
        .processors([.resize(size: size.cgSize, contentMode: .aspectFill, upscale: true)])
        .priority(imagePriority)
        .aspectRatio(1, contentMode: .fill)
        .frame(maxWidth: size.cgSize.width, maxHeight: size.cgSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .id(loadID)  // Force view recreation only when artwork actually changes
        .onChange(of: loadID) { _ in
            // Clear artwork URL immediately when track changes to prevent stale display
            artworkURL = nil
        }
        .task(id: "\(loadID)|\(invalidationToken)") {
            await loadArtworkURL()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ArtworkLoader.artworkDidInvalidate)
        ) { notification in
            // Re-trigger load if this artwork's ratingKey was invalidated
            guard let invalidatedKey = notification.userInfo?["ratingKey"] as? String else { return }
            let effectiveKey = (path == nil || path?.isEmpty == true) ? fallbackRatingKey : ratingKey
            if invalidatedKey == effectiveKey {
                artworkURL = nil
                invalidationToken += 1
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ArtworkLoader.serversBecameAvailable)
        ) { _ in
            // Re-trigger if we're showing a local-file fallback (from the startup race)
            // so we can attempt the network URL now that the server is available
            if let url = artworkURL, url.isFileURL {
                invalidationToken += 1
            }
        }
    }
    
    private func loadArtworkURL() async {
        let actualPath = (path == nil || path?.isEmpty == true) ? fallbackPath : path
        let actualRatingKey = (path == nil || path?.isEmpty == true) ? fallbackRatingKey : ratingKey
        
        guard let finalPath = actualPath else {
            #if DEBUG
            EnsembleLogger.debug("🎨 ArtworkView[\(size.rawValue)]: No path available - primary:\(path ?? "nil") fallback:\(fallbackPath ?? "nil")")
            #endif
            // Clear artwork URL when no path is available
            artworkURL = nil
            return
        }
        
        #if DEBUG
        EnsembleLogger.debug("🎨 ArtworkView[\(size.rawValue)]: Loading - path:\(finalPath) ratingKey:\(actualRatingKey ?? "nil")")
        #endif
        
        let url = await dependencies.artworkLoader.artworkURLAsync(
            for: path,
            sourceKey: sourceKey,
            ratingKey: ratingKey,
            fallbackPath: fallbackPath,
            fallbackRatingKey: fallbackRatingKey,
            size: size.rawValue
        )
        
        // Update artwork URL (even if nil, to clear previous artwork)
        if url != artworkURL {
            #if DEBUG
            EnsembleLogger.debug("🎨 ArtworkView[\(size.rawValue)]: Got URL - \(url?.absoluteString ?? "nil")")
            #endif
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
