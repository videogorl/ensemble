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
        .frame(width: ArtworkSize.thumbnail.cgSize.width)
        .multilineTextAlignment(.leading)
    }
}

// MARK: - Album Grid

public struct AlbumGrid: View {
    private struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }

    let albums: [Album]
    let nowPlayingVM: NowPlayingViewModel
    let onAlbumTap: ((Album) -> Void)?

    @Environment(\.dependencies) private var deps
    @ObservedObject private var pinManager = DependencyContainer.shared.pinManager
    @State private var playlistPickerPayload: PlaylistPickerPayload?

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 16, alignment: .top)
    ]

    public init(albums: [Album], nowPlayingVM: NowPlayingViewModel, onAlbumTap: ((Album) -> Void)? = nil) {
        self.albums = albums
        self.nowPlayingVM = nowPlayingVM
        self.onAlbumTap = onAlbumTap
    }

    public var body: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(albums) { album in
                if #available(iOS 16.0, macOS 13.0, *) {
                    NavigationLink(value: NavigationCoordinator.Destination.album(id: album.id)) {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        albumContextMenu(album)
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
                        albumContextMenu(album)
                    }
                }
            }
        }
        .padding(.horizontal)
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(nowPlayingVM: nowPlayingVM, tracks: payload.tracks, title: payload.title)
        }
    }

    @ViewBuilder
    private func albumContextMenu(_ album: Album) -> some View {
        let isDownloaded = deps.offlineDownloadService.isAlbumDownloadEnabled(album)

        Button {
            withAlbumTracks(album) { tracks in
                nowPlayingVM.play(tracks: tracks)
            }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            withAlbumTracks(album) { tracks in
                nowPlayingVM.shufflePlay(tracks: tracks)
            }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            withAlbumTracks(album) { tracks in
                nowPlayingVM.playNext(tracks)
            }
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            withAlbumTracks(album) { tracks in
                nowPlayingVM.playLast(tracks)
            }
        } label: {
            Label("Play Last", systemImage: "text.append")
        }

        Button {
            withAlbumTracks(album) { tracks in
                nowPlayingVM.enableRadio(tracks: tracks)
            }
        } label: {
            Label("Radio", systemImage: "dot.radiowaves.left.and.right")
        }

        Button {
            withAlbumTracks(album) { tracks in
                playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: "Add Album to Playlist")
            }
        } label: {
            Label("Add to Playlist…", systemImage: "text.badge.plus")
        }

        Button {
            Task {
                await deps.offlineDownloadService.setAlbumDownloadEnabled(album, isEnabled: !isDownloaded)
            }
        } label: {
            Label(
                isDownloaded ? "Remove Download" : "Download",
                systemImage: isDownloaded ? "xmark.circle" : "arrow.down.circle"
            )
        }

        if let artistId = album.artistRatingKey {
            Button {
                DependencyContainer.shared.navigationCoordinator.push(.artist(id: artistId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
            } label: {
                Label("Go to Artist", systemImage: "person.circle")
            }
        }

        if let recentTarget = nowPlayingVM.lastPlaylistTarget {
            Button {
                addAlbumToRecentPlaylist(album, expectedTitle: recentTarget.title)
            } label: {
                Label("Add to \(recentTarget.title)", systemImage: "clock.arrow.circlepath")
            }
        }

        let isPinned = pinManager.isPinned(id: album.id)
        Button {
            if isPinned {
                pinManager.unpin(id: album.id)
            } else {
                pinManager.pin(
                    id: album.id,
                    sourceKey: album.sourceCompositeKey ?? "",
                    type: .album,
                    title: album.title
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

    private func withAlbumTracks(_ album: Album, perform action: @escaping ([Track]) -> Void) {
        Task {
            let tracks = await resolveTracks(for: album)
            guard !tracks.isEmpty else {
                await MainActor.run {
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: "exclamationmark.triangle.fill",
                            title: "No tracks available",
                            message: "Try again after the album finishes loading.",
                            dedupeKey: "album-menu-empty-\(album.id)"
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

    private func resolveTracks(for album: Album) async -> [Track] {
        if let cached = try? await deps.libraryRepository.fetchTracks(forAlbum: album.id),
           !cached.isEmpty {
            return cached.map { Track(from: $0) }
        }
        guard let sourceKey = album.sourceCompositeKey else { return [] }
        return (try? await deps.syncCoordinator.getAlbumTracks(albumId: album.id, sourceKey: sourceKey)) ?? []
    }

    private func addAlbumToRecentPlaylist(_ album: Album, expectedTitle: String) {
        withAlbumTracks(album) { tracks in
            Task {
                guard let playlist = await nowPlayingVM.resolveLastPlaylistTarget(for: tracks) else {
                    await MainActor.run {
                        deps.toastCenter.show(
                            ToastPayload(
                                style: .warning,
                                iconSystemName: "exclamationmark.triangle.fill",
                                title: "Can’t add to \(expectedTitle)",
                                message: "This album isn’t compatible with that playlist.",
                                dedupeKey: "album-recent-playlist-incompatible-\(album.id)"
                            )
                        )
                    }
                    return
                }

                _ = try? await nowPlayingVM.addTracks(tracks, to: playlist)
            }
        }
    }
}
