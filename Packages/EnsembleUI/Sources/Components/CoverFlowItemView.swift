import SwiftUI
import EnsembleCore

/// View for displaying an album or playlist in the CoverFlow carousel
struct CoverFlowItemView: View {
    let title: String
    let subtitle: String?
    let ratingKey: String
    let thumbPath: String?
    let sourceCompositeKey: String?
    let isAlbum: Bool
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 8) {
                // Artwork - responsive to parent width, forced 1:1 aspect ratio
                ArtworkView(
                    path: thumbPath,
                    sourceKey: sourceCompositeKey,
                    ratingKey: ratingKey,
                    size: .large
                )
                .aspectRatio(1, contentMode: .fill)
                .frame(width: geometry.size.width, height: geometry.size.width)
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 5)
                
                // Title and subtitle
                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold)) // Slightly larger title
                        .lineLimit(1)
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                    
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                            .foregroundColor(Color(white: 0.8))
                            .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}


// MARK: - Convenience Initializers

extension CoverFlowItemView {
    init(album: Album) {
        self.title = album.title
        self.subtitle = album.artistName
        self.ratingKey = album.id
        self.thumbPath = album.thumbPath
        self.sourceCompositeKey = album.sourceCompositeKey
        self.isAlbum = true
    }
    
    init(playlist: Playlist) {
        self.title = playlist.title
        self.subtitle = playlist.summary
        self.ratingKey = playlist.id
        self.thumbPath = playlist.compositePath
        self.sourceCompositeKey = playlist.sourceCompositeKey
        self.isAlbum = false
    }
}

// MARK: - Preview

struct CoverFlowItemView_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 40) {
            CoverFlowItemView(
                title: "Abbey Road",
                subtitle: "The Beatles",
                ratingKey: "123",
                thumbPath: nil,
                sourceCompositeKey: "test",
                isAlbum: true
            )
            
            CoverFlowItemView(
                title: "Road Trip Mix",
                subtitle: "52 songs",
                ratingKey: "456",
                thumbPath: nil,
                sourceCompositeKey: "test",
                isAlbum: false
            )
        }
        .padding()
        .background(Color.black)
    }
}
