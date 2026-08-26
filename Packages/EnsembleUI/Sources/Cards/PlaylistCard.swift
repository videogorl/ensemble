import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

public struct PlaylistCard: View {
    let playlist: Playlist
    let onTap: (() -> Void)?
    let allowsDragExport: Bool

    public init(
        playlist: Playlist,
        onTap: (() -> Void)? = nil,
        allowsDragExport: Bool = true
    ) {
        self.playlist = playlist
        self.onTap = onTap
        self.allowsDragExport = allowsDragExport
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.MediaCard.contentSpacing) {
            ArtworkView(playlist: playlist, size: .thumbnail)

            VStack(alignment: .leading, spacing: EnsembleScaffold.MediaCard.textSpacing) {
                Text(playlist.title)
                    .font(EnsembleDesign.Typography.cardTitle)
                    .lineLimit(2)
                    .foregroundColor(EnsembleDesign.Color.primaryText)

                Text("\(playlist.trackCount) songs")
                    .font(EnsembleDesign.Typography.cardSubtitle)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        }
        .frame(width: ArtworkSize.thumbnail.cgSize.width)
        .contentShape(Rectangle())
        .if(onTap != nil) { view in
            view.onTapGesture {
                onTap?()
            }
        }
        .if(allowsDragExport) { view in
            view.onDrag {
                MediaDragExportPolicy.itemProvider(for: MediaDragPayload.playlist(playlist))
            }
        }
    }
}

// MARK: - Playlist Row

/// List row for a single or merged playlist entry.
/// Handles navigation to either a single playlist or merged playlist detail.
public struct PlaylistRow: View {
    let displayPlaylist: DisplayPlaylist
    let chipStyle: PlaylistRowChip.Style?
    let onTap: (() -> Void)?
    let isDisabled: Bool
    let statusText: String?

    public init(
        displayPlaylist: DisplayPlaylist,
        chipStyle: PlaylistRowChip.Style? = nil,
        onTap: (() -> Void)? = nil,
        isDisabled: Bool = false,
        statusText: String? = nil
    ) {
        self.displayPlaylist = displayPlaylist
        self.chipStyle = chipStyle
        self.onTap = onTap
        self.isDisabled = isDisabled
        self.statusText = statusText
    }

    public var body: some View {
        if let onTap, !isDisabled {
            Button(action: onTap) {
                playlistRowContent
            }
            .buttonStyle(.plain)
        } else {
            playlistRowContent
        }
    }

    private var playlistRowContent: some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            PlaylistArtwork(
                displayPlaylist: displayPlaylist,
                size: .tiny,
                cornerRadius: ArtworkCornerRadius.square(for: .tiny)
            )

            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xs) {
                Text(displayPlaylist.title)
                    .font(EnsembleDesign.Typography.rowPrimary)
                    .lineLimit(1)
                    .foregroundColor(EnsembleDesign.Color.primaryText)

                HStack(spacing: EnsembleDesign.Spacing.xs) {
                    // Smart playlist icon always shows when applicable
                    if displayPlaylist.isSmart {
                        Image(systemName: EnsembleDesign.Icon.smartPlaylist)
                            .font(EnsembleDesign.Typography.cardMetadata)
                    }
                    Text(statusText ?? "\(displayPlaylist.trackCount) songs")
                        .font(EnsembleDesign.Typography.rowSecondary)
                }
                .foregroundColor(EnsembleDesign.Color.secondaryText)
            }

            Spacer()

            // Chip: shows merge icon or server name for name collisions
            if let chipStyle {
                PlaylistRowChip(style: chipStyle)
            }

            if isDisabled {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .contentShape(Rectangle())
        .opacity(isDisabled ? 0.55 : 1.0)
        .onDrag {
            MediaDragExportPolicy.itemProvider(for: MediaDragPayload.displayPlaylist(displayPlaylist))
        }
    }
}

// MARK: - Playlist Row Chip

/// A small capsule badge shown on playlist rows to indicate merge status
/// or server name when there are name collisions across servers.
public struct PlaylistRowChip: View {
    public enum Style {
        /// Shows the server name (when merge is off and names collide across servers)
        case serverName(String)
        /// Shows a merge icon (when this entry is a merged playlist)
        case merged
    }

    let style: Style

    public init(style: Style) {
        self.style = style
    }

    public var body: some View {
        Group {
            switch style {
            case .serverName(let name):
                Text(name)
                    .font(EnsembleDesign.Typography.cardMetadata)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
                    .padding(.horizontal, EnsembleScaffold.Chip.badgeHorizontalPadding)
                    .padding(.vertical, EnsembleScaffold.Chip.badgeVerticalPadding)
                    .background(
                        Capsule()
                            .fill(EnsembleDesign.Color.neutralBadge)
                    )
            case .merged:
                Image(systemName: EnsembleDesign.Icon.merge)
                    .font(EnsembleDesign.Typography.cardMetadata)
                    .foregroundColor(EnsembleDesign.Color.accent)
                    .padding(.horizontal, EnsembleScaffold.Chip.iconBadgeHorizontalPadding)
                    .padding(.vertical, EnsembleScaffold.Chip.badgeVerticalPadding)
                    .background(
                        Capsule()
                            .fill(EnsembleDesign.Color.accentBadge)
                    )
            }
        }
        .lineLimit(1)
    }
}
