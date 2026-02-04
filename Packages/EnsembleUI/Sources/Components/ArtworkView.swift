import EnsembleCore
import SwiftUI
import Nuke
import NukeUI

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
        LazyImage(url: artworkURL) { state in
            if let image = state.image {
                image
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
            } else if state.error != nil {
                placeholderContent
            } else {
                placeholderContent
                    .overlay {
                        ProgressView()
                            .tint(.secondary)
                    }
            }
        }
        .processors([.resize(size: CGSize(width: size.cgSize.width, height: size.cgSize.height), contentMode: .aspectFill)])
        .frame(width: size.cgSize.width, height: size.cgSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: path) {
            artworkURL = await dependencies.artworkLoader.artworkURLAsync(for: path, sourceKey: sourceKey, size: size.rawValue)
        }
    }

    private var placeholderContent: some View {
        ZStack {
            Color.gray.opacity(0.2)
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
