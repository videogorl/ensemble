import EnsembleCore
import SwiftUI

public struct PlaylistCard: View {
    let playlist: Playlist
    let onTap: (() -> Void)?

    public init(playlist: Playlist, onTap: (() -> Void)? = nil) {
        self.playlist = playlist
        self.onTap = onTap
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
        .onDrag {
            MediaDragExportPolicy.itemProvider(for: MediaDragPayload.playlist(playlist))
        }
    }
}

// MARK: - Playlist Row

/// List row for a single or merged playlist entry.
/// Handles navigation to either a single playlist or merged playlist detail.
public struct PlaylistRow: View {
    let displayPlaylist: DisplayPlaylist
    let nowPlayingVM: NowPlayingViewModel
    let chipStyle: PlaylistRowChip.Style?
    let onTap: (() -> Void)?
    let isDisabled: Bool
    let statusText: String?

    public init(
        displayPlaylist: DisplayPlaylist,
        nowPlayingVM: NowPlayingViewModel,
        chipStyle: PlaylistRowChip.Style? = nil,
        onTap: (() -> Void)? = nil,
        isDisabled: Bool = false,
        statusText: String? = nil
    ) {
        self.displayPlaylist = displayPlaylist
        self.nowPlayingVM = nowPlayingVM
        self.chipStyle = chipStyle
        self.onTap = onTap
        self.isDisabled = isDisabled
        self.statusText = statusText
    }

    public var body: some View {
        if let onTap {
            playlistRowContent
                .onTapGesture(perform: onTap)
        } else if #available(iOS 16.0, macOS 13.0, *) {
            if isDisabled {
                playlistRowContent
            } else {
                NavigationLink(value: navigationDestination) {
                    playlistRowContent
                }
                .buttonStyle(.plain)
            }
        } else {
            // iOS 15 fallback
            Group {
                if isDisabled {
                    playlistRowContent
                } else if displayPlaylist.isMerged {
                    NavigationLink {
                        MergedPlaylistDetailLoader(
                            title: displayPlaylist.title,
                            isSmart: displayPlaylist.isSmart,
                            nowPlayingVM: nowPlayingVM
                        )
                    } label: {
                        playlistRowContent
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        PlaylistDetailLoader(
                            playlistId: displayPlaylist.primaryPlaylist.id,
                            playlistSourceKey: displayPlaylist.primaryPlaylist.sourceCompositeKey,
                            nowPlayingVM: nowPlayingVM
                        )
                    } label: {
                        playlistRowContent
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Navigation destination for iOS 16+ value-based NavigationLink
    private var navigationDestination: NavigationCoordinator.Destination {
        if displayPlaylist.isMerged {
            return .mergedPlaylist(title: displayPlaylist.title, isSmart: displayPlaylist.isSmart)
        }
        return .playlist(
            id: displayPlaylist.primaryPlaylist.id,
            sourceKey: displayPlaylist.primaryPlaylist.sourceCompositeKey
        )
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
