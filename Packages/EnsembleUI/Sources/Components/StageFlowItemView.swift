import EnsembleCore
import SwiftUI

/// Artwork card used by StageFlow surfaces.
struct StageFlowItemView: View {
    let ratingKey: String
    let artworkPath: String?
    let sourceCompositeKey: String?

    var body: some View {
        ArtworkView(
            path: artworkPath,
            sourceKey: sourceCompositeKey,
            ratingKey: ratingKey,
            size: .large
        )
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.42), radius: 18, x: 0, y: 12)
    }
}

extension StageFlowItemView {
    init(album: Album) {
        self.init(
            ratingKey: album.id,
            artworkPath: album.thumbPath,
            sourceCompositeKey: album.sourceCompositeKey
        )
    }

    init(playlist: Playlist) {
        self.init(
            ratingKey: playlist.id,
            artworkPath: playlist.compositePath,
            sourceCompositeKey: playlist.sourceCompositeKey
        )
    }

    init(albumItem: SongsStageFlowAlbum) {
        self.init(
            ratingKey: albumItem.albumID,
            artworkPath: albumItem.thumbPath,
            sourceCompositeKey: albumItem.sourceCompositeKey
        )
    }
}
