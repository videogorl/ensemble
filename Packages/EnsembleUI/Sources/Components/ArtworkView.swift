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
    
    // Unique ID to identify this specific artwork request
    private var loadID: String {
        let actualPath = (path == nil || path?.isEmpty == true) ? fallbackPath : path
        let actualRatingKey = (path == nil || path?.isEmpty == true) ? fallbackRatingKey : ratingKey
        return "\(actualPath ?? "")|\(actualRatingKey ?? "")|\(sourceKey ?? "")|\(size.rawValue)"
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
                } else if let error = state.error {
                    // Show placeholder on error
                    let _ = EnsembleLogger.debug("🎨 ArtworkView[\(size.rawValue)]: Load error - \(error.localizedDescription) for URL: \(artworkURL?.absoluteString ?? "nil")")
                    Image(systemName: "music.note")
                        .font(.system(size: size.cgSize.width * 0.3))
                        .foregroundColor(.gray.opacity(0.5))
                } else {
                    // Loading or no URL yet
                    let _ = EnsembleLogger.debug("🎨 ArtworkView[\(size.rawValue)]: Loading state - URL: \(artworkURL?.absoluteString ?? "nil")")
                    Image(systemName: "music.note")
                        .font(.system(size: size.cgSize.width * 0.3))
                        .foregroundColor(.gray.opacity(0.5))
                }
            }
        }
        .processors([.resize(size: size.cgSize, contentMode: .aspectFill, upscale: true)])
        .priority(.high)
        .aspectRatio(1, contentMode: .fill)
        .frame(maxWidth: size.cgSize.width, maxHeight: size.cgSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .id(loadID)  // Force view recreation only when artwork actually changes
        .task(id: loadID) {
            await loadArtworkURL()
        }
    }
    
    private func loadArtworkURL() async {
        let actualPath = (path == nil || path?.isEmpty == true) ? fallbackPath : path
        let actualRatingKey = (path == nil || path?.isEmpty == true) ? fallbackRatingKey : ratingKey
        
        guard let finalPath = actualPath else {
            #if DEBUG
            EnsembleLogger.debug("🎨 ArtworkView[\(size.rawValue)]: No path available - primary:\(path ?? "nil") fallback:\(fallbackPath ?? "nil")")
            #endif
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
        
        // Only update if URL actually changed
        if url != artworkURL {
            #if DEBUG
            EnsembleLogger.debug("🎨 ArtworkView[\(size.rawValue)]: Got URL - \(url?.absoluteString ?? "nil")")
            #endif
            artworkURL = url
        } else {
            #if DEBUG
            EnsembleLogger.debug("🎨 ArtworkView[\(size.rawValue)]: URL unchanged")
            #endif
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
