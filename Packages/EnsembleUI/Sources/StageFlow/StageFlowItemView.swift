import EnsembleCore
import SwiftUI

private enum StageFlowItemChromeMetrics {
    static let artworkBorderOpacity = 0.08
    static let artworkBorderWidth: CGFloat = 1
    static let artworkShadowOpacity = 0.42
    static let artworkShadowRadius: CGFloat = 18
    static let artworkShadowX = EnsembleDesign.Spacing.none
    static let artworkShadowY = EnsembleDesign.Spacing.md
}

/// Artwork card used by StageFlow surfaces.
struct StageFlowItemView: View {
    let ratingKey: String
    let artworkPath: String?
    let sourceCompositeKey: String?
    /// When set, uses composite artwork (2x2 grid for merged playlists)
    let displayPlaylist: DisplayPlaylist?

    init(ratingKey: String, artworkPath: String?, sourceCompositeKey: String?, displayPlaylist: DisplayPlaylist? = nil) {
        self.ratingKey = ratingKey
        self.artworkPath = artworkPath
        self.sourceCompositeKey = sourceCompositeKey
        self.displayPlaylist = displayPlaylist
    }

    var body: some View {
        let artworkCornerRadius = ArtworkCornerRadius.square(for: ArtworkSize.large)

        artworkContent
            .aspectRatio(1, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(StageFlowItemChromeMetrics.artworkBorderOpacity),
                        lineWidth: StageFlowItemChromeMetrics.artworkBorderWidth
                    )
            )
            .shadow(
                color: .black.opacity(StageFlowItemChromeMetrics.artworkShadowOpacity),
                radius: StageFlowItemChromeMetrics.artworkShadowRadius,
                x: StageFlowItemChromeMetrics.artworkShadowX,
                y: StageFlowItemChromeMetrics.artworkShadowY
            )
    }

    @ViewBuilder
    private var artworkContent: some View {
        if let dp = displayPlaylist, dp.isMerged {
            PlaylistArtwork(displayPlaylist: dp, size: .large, cornerRadius: EnsembleDesign.Spacing.none, isResponsive: true)
        } else {
            ArtworkView(
                path: artworkPath,
                sourceKey: sourceCompositeKey,
                ratingKey: ratingKey,
                size: .large,
                cornerRadius: EnsembleDesign.Spacing.none,
                isResponsive: true
            )
        }
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

    init(displayPlaylist dp: DisplayPlaylist) {
        self.init(
            ratingKey: dp.primaryPlaylist.id,
            artworkPath: dp.compositePath,
            sourceCompositeKey: dp.sourceCompositeKey,
            displayPlaylist: dp.isMerged ? dp : nil
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
