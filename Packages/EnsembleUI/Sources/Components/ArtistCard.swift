import EnsembleCore
import SwiftUI

public struct ArtistCard: View {
    let artist: Artist
    let onTap: (() -> Void)?

    public init(artist: Artist, onTap: (() -> Void)? = nil) {
        self.artist = artist
        self.onTap = onTap
    }

    public var body: some View {
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
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }
}

// MARK: - Artist Row

public struct ArtistRow: View {
    let artist: Artist
    let onTap: (() -> Void)?

    public init(artist: Artist, onTap: (() -> Void)? = nil) {
        self.artist = artist
        self.onTap = onTap
    }

    public var body: some View {
        HStack(spacing: 12) {
            ArtworkView(artist: artist, size: .tiny, cornerRadius: 22)

            Text(artist.name)
                .font(.body)
                .lineLimit(1)
                .foregroundColor(.primary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }
}

// MARK: - Artist Grid

public struct ArtistGrid: View {
    let artists: [Artist]
    let nowPlayingVM: NowPlayingViewModel
    let onArtistTap: ((Artist) -> Void)?
    @Environment(\.dependencies) private var deps

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
                if #available(iOS 16.0, *) {
                    NavigationLink(value: NavigationCoordinator.Destination.artist(id: artist.id)) {
                        artistCardContent(artist)
                    }
                    .buttonStyle(.plain)
                } else {
                    // iOS 15 fallback: using legacy NavigationLink for nested navigation support
                    NavigationLink {
                        ArtistDetailLoader(artistId: artist.id, nowPlayingVM: nowPlayingVM)
                    } label: {
                        artistCardContent(artist)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal)
    }
    
    private func artistCardContent(_ artist: Artist) -> some View {
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
}