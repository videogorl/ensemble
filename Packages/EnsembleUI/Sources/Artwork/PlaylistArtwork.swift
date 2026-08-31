import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

// MARK: - Playlist Artwork

/// Artwork from the preferred constituent of a single or merged playlist.
struct PlaylistArtwork: View {
    let displayPlaylist: DisplayPlaylist
    let size: ArtworkSize
    let cornerRadius: CGFloat
    let isResponsive: Bool

    init(
        displayPlaylist: DisplayPlaylist,
        size: ArtworkSize = .medium,
        cornerRadius: CGFloat? = nil,
        isResponsive: Bool = false
    ) {
        self.displayPlaylist = displayPlaylist
        self.size = size
        self.cornerRadius = cornerRadius ?? ArtworkCornerRadius.square(for: size)
        self.isResponsive = isResponsive
    }

    var body: some View {
        ArtworkView(
            playlist: displayPlaylist.primaryPlaylist,
            size: size,
            cornerRadius: cornerRadius,
            isResponsive: isResponsive
        )
    }
}

// MARK: - Display Playlist Card

/// Grid card for a DisplayPlaylist with aggregated track count from all constituents.
public struct DisplayPlaylistCard: View {
    let displayPlaylist: DisplayPlaylist

    public init(displayPlaylist: DisplayPlaylist) {
        self.displayPlaylist = displayPlaylist
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.MediaCard.contentSpacing) {
            PlaylistArtwork(displayPlaylist: displayPlaylist, size: .thumbnail, isResponsive: true)
                .mediaNavigationTransitionSource(id: displayPlaylist.primaryPlaylist.sourceScopedID)

            VStack(alignment: .leading, spacing: EnsembleScaffold.MediaCard.textSpacing) {
                Text(displayPlaylist.title)
                    .font(EnsembleDesign.Typography.cardTitle)
                    .lineLimit(2)
                    .foregroundColor(EnsembleDesign.Color.primaryText)

                Text("\(displayPlaylist.trackCount) songs")
                    .font(EnsembleDesign.Typography.cardSubtitle)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}
