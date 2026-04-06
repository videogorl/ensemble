import EnsembleCore
import SwiftUI

/// Shared sizing rules for album-focused card grids so the larger artwork stays
/// consistent between shelves and full-screen album browsing surfaces.
public enum AlbumCardLayoutMetrics {
    case compact
    case prominent

    public var artworkSize: ArtworkSize {
        switch self {
        case .compact:
            return .thumbnail
        case .prominent:
            return .card
        }
    }

    public var gridSpacing: CGFloat { 16 }
    public var rowSpacing: CGFloat { 20 }

    public var columnMinimum: CGFloat {
        switch self {
        case .compact:
            return 100
        case .prominent:
            return 150
        }
    }

    public var columnMaximum: CGFloat {
        switch self {
        case .compact:
            return 120
        case .prominent:
            return 180
        }
    }

    public var horizontalScrollHeight: CGFloat {
        artworkSize.cgSize.height + 78
    }

    public var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: columnMinimum, maximum: columnMaximum), spacing: gridSpacing, alignment: .top)]
    }
}

public struct AlbumCard: View {
    let album: Album
    let layout: AlbumCardLayoutMetrics

    public init(album: Album, layout: AlbumCardLayoutMetrics = .compact) {
        self.album = album
        self.layout = layout
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(album: album, size: layout.artworkSize)

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
        .frame(width: layout.artworkSize.cgSize.width)
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
    let layout: AlbumCardLayoutMetrics

    @Environment(\.dependencies) private var deps
    @State private var playlistPickerPayload: PlaylistPickerPayload?

    public init(
        albums: [Album],
        nowPlayingVM: NowPlayingViewModel,
        layout: AlbumCardLayoutMetrics = .prominent,
        onAlbumTap: ((Album) -> Void)? = nil
    ) {
        self.albums = albums
        self.nowPlayingVM = nowPlayingVM
        self.layout = layout
        self.onAlbumTap = onAlbumTap
    }

    public var body: some View {
        LazyVGrid(columns: layout.gridColumns, spacing: layout.rowSpacing) {
            ForEach(albums) { album in
                if #available(iOS 16.0, macOS 13.0, *) {
                    NavigationLink(value: NavigationCoordinator.Destination.album(id: album.id)) {
                        AlbumCard(album: album, layout: layout)
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
                        AlbumCard(album: album, layout: layout)
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
