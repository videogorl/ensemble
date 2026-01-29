import EnsembleCore
import SwiftUI

public struct ArtistCard: View {
    let artist: Artist
    let onTap: () -> Void

    public init(artist: Artist, onTap: @escaping () -> Void) {
        self.artist = artist
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                ArtworkView(artist: artist, size: .medium, cornerRadius: ArtworkSize.medium.cgSize.width / 2)

                Text(artist.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            .frame(width: ArtworkSize.medium.cgSize.width)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Artist Row

public struct ArtistRow: View {
    let artist: Artist
    let onTap: () -> Void

    public init(artist: Artist, onTap: @escaping () -> Void) {
        self.artist = artist
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ArtworkView(artist: artist, size: .thumbnail, cornerRadius: 22)
                    .frame(width: 44, height: 44)

                Text(artist.name)
                    .font(.body)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Artist Grid

public struct ArtistGrid: View {
    let artists: [Artist]
    let onArtistTap: (Artist) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)
    ]

    public init(artists: [Artist], onArtistTap: @escaping (Artist) -> Void) {
        self.artists = artists
        self.onArtistTap = onArtistTap
    }

    public var body: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(artists) { artist in
                ArtistCard(artist: artist) {
                    onArtistTap(artist)
                }
            }
        }
        .padding(.horizontal)
    }
}
