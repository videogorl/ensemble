import EnsembleDesignTokens
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
    let identity: ArtworkRequest.Identity?

    init(
        ratingKey: String,
        artworkPath: String?,
        sourceCompositeKey: String?,
        identity: ArtworkRequest.Identity? = nil
    ) {
        self.ratingKey = ratingKey
        self.artworkPath = artworkPath
        self.sourceCompositeKey = sourceCompositeKey
        self.identity = identity
    }

    var body: some View {
        let artworkCornerRadius = ArtworkCornerRadius.square(for: ArtworkSize.large)

        ArtworkView(
            path: artworkPath,
            sourceKey: sourceCompositeKey,
            ratingKey: ratingKey,
            identity: identity,
            size: .large,
            cornerRadius: EnsembleDesign.Spacing.none,
            isResponsive: true
        )
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
}

extension StageFlowItemView {
    init(album: Album) {
        self.init(
            ratingKey: album.id,
            artworkPath: album.thumbPath,
            sourceCompositeKey: album.sourceCompositeKey,
            identity: ArtworkRequest.Identity(album: album)
        )
    }

    init(displayPlaylist dp: DisplayPlaylist) {
        self.init(
            ratingKey: dp.primaryPlaylist.id,
            artworkPath: dp.compositePath,
            sourceCompositeKey: dp.sourceCompositeKey,
            identity: ArtworkRequest.Identity(playlist: dp.primaryPlaylist)
        )
    }

    init(albumItem: SongsStageFlowAlbum) {
        self.init(
            ratingKey: albumItem.albumID,
            artworkPath: albumItem.thumbPath,
            sourceCompositeKey: albumItem.sourceCompositeKey,
            identity: ArtworkRequest.Identity(
                ratingKey: albumItem.albumID,
                kind: .album,
                sourcePath: albumItem.thumbPath
            )
        )
    }
}
