import EnsembleCore
import SwiftUI

public struct AlbumCard: View {
    let album: Album
    let onTap: () -> Void

    public init(album: Album, onTap: @escaping () -> Void) {
        self.album = album
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(album: album, size: .medium)

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

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
            .frame(width: ArtworkSize.medium.cgSize.width)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Album Grid

public struct AlbumGrid: View {
    let albums: [Album]
    let onAlbumTap: (Album) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)
    ]

    public init(albums: [Album], onAlbumTap: @escaping (Album) -> Void) {
        self.albums = albums
        self.onAlbumTap = onAlbumTap
    }

    public var body: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(albums) { album in
                AlbumCard(album: album) {
                    onAlbumTap(album)
                }
            }
        }
        .padding(.horizontal)
    }
}
