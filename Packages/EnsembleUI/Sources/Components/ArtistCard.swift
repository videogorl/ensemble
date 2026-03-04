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
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)
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
        .if(onTap != nil) { view in
            view.onTapGesture {
                onTap?()
            }
        }
    }
}

// MARK: - Artist Grid

public struct ArtistGrid: View {
    let artists: [Artist]
    let nowPlayingVM: NowPlayingViewModel
    let onArtistTap: ((Artist) -> Void)?
    @Environment(\.dependencies) private var deps
    @ObservedObject private var pinManager = DependencyContainer.shared.pinManager

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 16, alignment: .top)
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
                if #available(iOS 16.0, macOS 13.0, *) {
                    NavigationLink(value: NavigationCoordinator.Destination.artist(id: artist.id)) {
                        artistCardContent(artist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        artistContextMenu(artist)
                    }
                } else {
                    // iOS 15 fallback: using legacy NavigationLink for nested navigation support
                    NavigationLink {
                        ArtistDetailLoader(artistId: artist.id, nowPlayingVM: nowPlayingVM)
                    } label: {
                        artistCardContent(artist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        artistContextMenu(artist)
                    }
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

    @ViewBuilder
    private func artistContextMenu(_ artist: Artist) -> some View {
        let isDownloaded = deps.offlineDownloadService.isArtistDownloadEnabled(artist)

        Button {
            withArtistTracks(artist) { tracks in
                nowPlayingVM.play(tracks: tracks)
            }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            withArtistTracks(artist) { tracks in
                nowPlayingVM.shufflePlay(tracks: tracks)
            }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            withArtistTracks(artist) { tracks in
                nowPlayingVM.enableRadio(tracks: tracks)
            }
        } label: {
            Label("Radio", systemImage: "dot.radiowaves.left.and.right")
        }

        Button {
            Task {
                await deps.offlineDownloadService.setArtistDownloadEnabled(artist, isEnabled: !isDownloaded)
            }
        } label: {
            Label(
                isDownloaded ? "Remove Download" : "Download",
                systemImage: isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle"
            )
        }

        let isPinned = pinManager.isPinned(id: artist.id)
        Button {
            if isPinned {
                pinManager.unpin(id: artist.id)
            } else {
                pinManager.pin(
                    id: artist.id,
                    sourceKey: artist.sourceCompositeKey ?? "",
                    type: .artist,
                    title: artist.name
                )
            }
        } label: {
            if isPinned {
                Label("Unpin", systemImage: "pin.slash")
            } else {
                Label("Pin", systemImage: "pin.fill")
            }
        }
    }

    private func withArtistTracks(_ artist: Artist, perform action: @escaping ([Track]) -> Void) {
        Task {
            let tracks = await resolveTracks(for: artist)
            guard !tracks.isEmpty else {
                await MainActor.run {
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: "exclamationmark.triangle.fill",
                            title: "No tracks available",
                            message: "Try again after the artist finishes loading.",
                            dedupeKey: "artist-menu-empty-\(artist.id)"
                        )
                    )
                }
                return
            }
            await MainActor.run {
                action(tracks)
            }
        }
    }

    private func resolveTracks(for artist: Artist) async -> [Track] {
        if let cached = try? await deps.libraryRepository.fetchTracks(forArtist: artist.id),
           !cached.isEmpty {
            return cached.map { Track(from: $0) }
        }
        guard let sourceKey = artist.sourceCompositeKey else { return [] }
        return (try? await deps.syncCoordinator.getArtistTracks(artistId: artist.id, sourceKey: sourceKey)) ?? []
    }
}
