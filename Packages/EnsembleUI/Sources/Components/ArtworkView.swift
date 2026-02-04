import EnsembleCore
import SwiftUI
import Nuke

public struct ArtworkView: View {
    let path: String?
    let sourceKey: String?
    let size: ArtworkSize
    let cornerRadius: CGFloat

    @Environment(\.dependencies) private var dependencies
    @State private var loadedImage: UIImage?
    @State private var isLoading = false

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
        ZStack {
            Color.gray.opacity(0.2)
            
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size.cgSize.width * 0.3))
                    .foregroundColor(.gray.opacity(0.5))
                
                if isLoading {
                    ProgressView()
                        .tint(.secondary)
                }
            }
        }
        .frame(width: size.cgSize.width, height: size.cgSize.height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: path) {
            await loadArtwork()
        }
    }
    
    private func loadArtwork() async {
        guard let url = await dependencies.artworkLoader.artworkURLAsync(
            for: path,
            sourceKey: sourceKey,
            size: size.rawValue
        ) else {
            return
        }
        
        isLoading = true
        
        let request = ImageRequest(
            url: url,
            processors: [.resize(size: size.cgSize, contentMode: .aspectFill)]
        )
        
        if let image = try? await ImagePipeline.shared.image(for: request) {
            await MainActor.run {
                self.loadedImage = image
                self.isLoading = false
            }
        } else {
            await MainActor.run {
                self.isLoading = false
            }
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
