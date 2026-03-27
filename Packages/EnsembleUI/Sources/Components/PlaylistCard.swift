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
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(playlist: playlist, size: .thumbnail)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundColor(.primary)

                Text("\(playlist.trackCount) songs")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: ArtworkSize.thumbnail.cgSize.width)
        .contentShape(Rectangle())
        .if(onTap != nil) { view in
            view.onTapGesture {
                onTap?()
            }
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
        if #available(iOS 16.0, macOS 13.0, *) {
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
        HStack(spacing: 12) {
            ArtworkView(playlist: displayPlaylist.primaryPlaylist, size: .tiny, cornerRadius: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayPlaylist.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundColor(.primary)

                HStack(spacing: 4) {
                    // Smart playlist icon always shows when applicable
                    if displayPlaylist.isSmart {
                        Image(systemName: "gearshape.fill")
                            .font(.caption2)
                    }
                    Text(statusText ?? "\(displayPlaylist.trackCount) songs")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
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
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                    )
            case .merged:
                Image(systemName: "arrow.triangle.merge")
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.15))
                    )
            }
        }
        .lineLimit(1)
    }
}
