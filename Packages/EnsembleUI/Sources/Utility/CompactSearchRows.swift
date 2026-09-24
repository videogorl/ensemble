import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

/// Compact row component for displaying search results with smaller artwork and inline layout
/// Used to show more results on screen at once in search interface

// MARK: - Compact Artist Row

public struct CompactArtistRow: View {
    let displayArtist: DisplayArtist

    public init(displayArtist: DisplayArtist) {
        self.displayArtist = displayArtist
    }

    public var body: some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            ArtworkView(
                artist: displayArtist.primaryArtist,
                size: .tiny,
                cornerRadius: ArtworkCornerRadius.circle(for: ArtworkSize.tiny.cgSize.width)
            )

            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.cardTextGap) {
                Text(displayArtist.name)
                    .font(EnsembleDesign.Typography.rowPrimary)
                    .lineLimit(1)
                    .foregroundColor(EnsembleDesign.Color.primaryText)

                if displayArtist.isMerged {
                    Text("\(displayArtist.artists.count) sources")
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .lineLimit(1)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
            }

            Spacer()

            Image(systemName: EnsembleDesign.Icon.chevronRight)
                .font(EnsembleDesign.Typography.rowSecondary)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
        .padding(.vertical, EnsembleScaffold.UtilityRow.tightVerticalPadding)
        .contentShape(Rectangle())
    }
}

// MARK: - Compact Album Row

public struct CompactAlbumRow: View {
    let album: Album

    public init(album: Album) {
        self.album = album
    }

    public var body: some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            ArtworkView(album: album, size: .tiny, cornerRadius: ArtworkCornerRadius.square(for: .tiny))
                .mediaNavigationTransitionSource(id: album.sourceScopedID)

            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.cardTextGap) {
                Text(album.title)
                    .font(EnsembleDesign.Typography.rowPrimary)
                    .lineLimit(1)
                    .foregroundColor(EnsembleDesign.Color.primaryText)

                if let artist = album.artistName {
                    Text(artist)
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: EnsembleDesign.Icon.chevronRight)
                .font(EnsembleDesign.Typography.rowSecondary)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
        .padding(.vertical, EnsembleScaffold.UtilityRow.tightVerticalPadding)
        .contentShape(Rectangle())
    }
}

// MARK: - Compact Playlist Row

public struct CompactPlaylistRow: View {
    let displayPlaylist: DisplayPlaylist

    public init(displayPlaylist: DisplayPlaylist) {
        self.displayPlaylist = displayPlaylist
    }

    public var body: some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            PlaylistArtwork(
                displayPlaylist: displayPlaylist,
                size: .tiny,
                cornerRadius: ArtworkCornerRadius.square(for: .tiny)
            )
            .mediaNavigationTransitionSource(id: displayPlaylist.primaryPlaylist.sourceScopedID)

            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.cardTextGap) {
                Text(displayPlaylist.title)
                    .font(EnsembleDesign.Typography.rowPrimary)
                    .lineLimit(1)
                    .foregroundColor(EnsembleDesign.Color.primaryText)

                HStack(spacing: EnsembleDesign.Spacing.xs) {
                    if displayPlaylist.isSmart {
                        Image(systemName: EnsembleDesign.Icon.smartPlaylist)
                            .font(EnsembleDesign.Typography.rowSecondary)
                    }
                    Text("\(displayPlaylist.trackCount) songs")
                        .font(EnsembleDesign.Typography.rowSecondary)
                }
                .foregroundColor(EnsembleDesign.Color.secondaryText)
            }

            Spacer()

            Image(systemName: EnsembleDesign.Icon.chevronRight)
                .font(EnsembleDesign.Typography.rowSecondary)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
        .padding(.vertical, EnsembleScaffold.UtilityRow.tightVerticalPadding)
        .contentShape(Rectangle())
    }
}
