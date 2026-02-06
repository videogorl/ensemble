import EnsembleCore
import SwiftUI

public struct AlbumCard: View {
    let album: Album

    public init(album: Album) {
        self.album = album
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(album: album, size: .thumbnail)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundColor(.primary)

                if let artist = album.artistName {
                    Text(artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if let year = album.year {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: ArtworkSize.thumbnail.cgSize.width)
        .multilineTextAlignment(.leading)
    }
}

// MARK: - Album Grid

public struct AlbumGrid: View {
    let albums: [Album]
    let nowPlayingVM: NowPlayingViewModel
    let onAlbumTap: ((Album) -> Void)?

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 16)
    ]

    public init(albums: [Album], nowPlayingVM: NowPlayingViewModel, onAlbumTap: ((Album) -> Void)? = nil) {
        self.albums = albums
        self.nowPlayingVM = nowPlayingVM
        self.onAlbumTap = onAlbumTap
    }

    public var body: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(albums) { album in
                if #available(iOS 16.0, *) {
                    NavigationLink(value: NavigationCoordinator.Destination.album(id: album.id)) {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                } else {
                    // iOS 15 fallback
                    NavigationLink {
                        AlbumDetailLoader(albumId: album.id, nowPlayingVM: nowPlayingVM)
                    } label: {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal)
    }
}