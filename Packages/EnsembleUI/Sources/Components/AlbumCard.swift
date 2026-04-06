import EnsembleCore
import SwiftUI

/// Shared sizing rules for album-focused card grids so the larger artwork stays
/// consistent between shelves and full-screen album browsing surfaces.
public enum AlbumCardLayoutMetrics {
    public static let artworkSize: ArtworkSize = .card
    public static let gridSpacing: CGFloat = 16
    public static let rowSpacing: CGFloat = 20
    public static let columnMinimum: CGFloat = 150
    public static let columnMaximum: CGFloat = 180
    public static let horizontalScrollHeight: CGFloat = artworkSize.cgSize.height + 78

    public static var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: columnMinimum, maximum: columnMaximum), spacing: gridSpacing, alignment: .top)]
    }
}

public struct AlbumCard: View {
    let album: Album

    public init(album: Album) {
        self.album = album
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(album: album, size: AlbumCardLayoutMetrics.artworkSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundColor(.primary)

                if let artist = album.artistName {
                    Text(artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                if let year = album.year {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: AlbumCardLayoutMetrics.artworkSize.cgSize.width)
        .multilineTextAlignment(.leading)
    }
}

// MARK: - Album Grid

public struct AlbumGrid: View {
    fileprivate struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }

    let albums: [Album]
    let nowPlayingVM: NowPlayingViewModel
    let onAlbumTap: ((Album) -> Void)?

    @Environment(\.dependencies) private var deps
    @State private var playlistPickerPayload: PlaylistPickerPayload?

    public init(albums: [Album], nowPlayingVM: NowPlayingViewModel, onAlbumTap: ((Album) -> Void)? = nil) {
        self.albums = albums
        self.nowPlayingVM = nowPlayingVM
        self.onAlbumTap = onAlbumTap
    }

    public var body: some View {
        LazyVGrid(columns: AlbumCardLayoutMetrics.gridColumns, spacing: AlbumCardLayoutMetrics.rowSpacing) {
            ForEach(albums) { album in
                if #available(iOS 16.0, macOS 13.0, *) {
                    NavigationLink(value: NavigationCoordinator.Destination.album(id: album.id)) {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        AlbumActionsContextMenu(album: album, nowPlayingVM: nowPlayingVM) { tracks, title in
                            playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: title)
                        }
                    }
                } else {
                    // iOS 15 fallback
                    NavigationLink {
                        AlbumDetailLoader(albumId: album.id, nowPlayingVM: nowPlayingVM)
                    } label: {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        AlbumActionsContextMenu(album: album, nowPlayingVM: nowPlayingVM) { tracks, title in
                            playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: title)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(nowPlayingVM: nowPlayingVM, tracks: payload.tracks, title: payload.title)
        }
    }

}
