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
                ArtworkView(artist: artist, size: .thumbnail, cornerRadius: ArtworkSize.thumbnail.cgSize.width / 2)

                Text(artist.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            .frame(width: ArtworkSize.thumbnail.cgSize.width)
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
                ArtworkView(artist: artist, size: .tiny, cornerRadius: 22)

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
    let nowPlayingVM: NowPlayingViewModel
    let onArtistTap: ((Artist) -> Void)?

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 16)
    ]

    public init(
        artists: [Artist],
        nowPlayingVM: NowPlayingViewModel,
        onArtistTap: ((Artist) -> Void)? = nil
    ) {
        self.artists = artists
        self.nowPlayingVM = nowPlayingVM
        self.onArtistTap = onArtistTap
    }

    public var body: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(artists) { artist in
                NavigationLink {
                    ArtistDetailView(
                        artist: artist,
                        nowPlayingVM: nowPlayingVM,
                        onAlbumTap: { album in
                            // Album navigation will be handled by AlbumDetailView
                        }
                    )
                } label: {
                    VStack(spacing: 8) {
                        ArtworkView(artist: artist, size: .thumbnail, cornerRadius: ArtworkSize.thumbnail.cgSize.width / 2)

                        Text(artist.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.primary)
                    }
                    .frame(width: ArtworkSize.thumbnail.cgSize.width)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    onArtistTap?(artist)
                })
            }
        }
        .padding(.horizontal)
    }
}
