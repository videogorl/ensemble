import EnsembleCore
import NukeUI
import SwiftUI

public struct ArtworkView: View {
    let path: String?
    let sourceKey: String?
    let size: ArtworkSize
    let cornerRadius: CGFloat

    @Environment(\.dependencies) private var dependencies
    @State private var artworkURL: URL?

    public init(
        path: String?,
        sourceKey: String? = nil,
        size: ArtworkSize = .medium,
        cornerRadius: CGFloat = 8
    ) {
        self.path = path
        self.sourceKey = sourceKey
        self.size = size
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        Group {
            if let url = artworkURL {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if state.error != nil {
                        placeholderView
                    } else {
                        placeholderView
                            .overlay {
                                ProgressView()
                                    .tint(.secondary)
                            }
                    }
                }
            } else {
                placeholderView
            }
        }
        .frame(width: size.cgSize.width, height: size.cgSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: path) {
            // Load artwork URL asynchronously
            artworkURL = await dependencies.artworkLoader.artworkURLAsync(for: path, sourceKey: sourceKey, size: size.rawValue)
        }
    }

    private var placeholderView: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.2))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size.cgSize.width * 0.3))
                    .foregroundColor(.gray.opacity(0.5))
            }
    }
}

// MARK: - Convenience Initializers

public extension ArtworkView {
    init(track: Track, size: ArtworkSize = .medium, cornerRadius: CGFloat = 8) {
        self.init(path: track.thumbPath, sourceKey: track.sourceCompositeKey, size: size, cornerRadius: cornerRadius)
    }

    init(album: Album, size: ArtworkSize = .medium, cornerRadius: CGFloat = 8) {
        self.init(path: album.thumbPath, sourceKey: album.sourceCompositeKey, size: size, cornerRadius: cornerRadius)
    }

    init(artist: Artist, size: ArtworkSize = .medium, cornerRadius: CGFloat = 8) {
        self.init(path: artist.thumbPath, sourceKey: artist.sourceCompositeKey, size: size, cornerRadius: cornerRadius)
    }

    init(playlist: Playlist, size: ArtworkSize = .medium, cornerRadius: CGFloat = 8) {
        self.init(path: playlist.compositePath, sourceKey: playlist.sourceCompositeKey, size: size, cornerRadius: cornerRadius)
    }
}
