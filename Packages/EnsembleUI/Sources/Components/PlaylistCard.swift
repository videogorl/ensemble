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

public struct PlaylistRow: View {
    let playlist: Playlist
    let nowPlayingVM: NowPlayingViewModel
    let onTap: (() -> Void)?

    public init(playlist: Playlist, nowPlayingVM: NowPlayingViewModel, onTap: (() -> Void)? = nil) {
        self.playlist = playlist
        self.nowPlayingVM = nowPlayingVM
        self.onTap = onTap
    }

    public var body: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            NavigationLink(value: NavigationCoordinator.Destination.playlist(id: playlist.id)) {
                playlistRowContent
            }
            .buttonStyle(.plain)
        } else {
            // iOS 15 fallback
            NavigationLink {
                PlaylistDetailLoader(playlistId: playlist.id, nowPlayingVM: nowPlayingVM)
            } label: {
                playlistRowContent
            }
            .buttonStyle(.plain)
        }
    }
    
    private var playlistRowContent: some View {
        HStack(spacing: 12) {
            ArtworkView(playlist: playlist, size: .tiny, cornerRadius: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundColor(.primary)

                HStack(spacing: 4) {
                    if playlist.isSmart {
                        Image(systemName: "gearshape.fill")
                            .font(.caption2)
                    }
                    Text("\(playlist.trackCount) songs")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }
}