import EnsembleCore
import SwiftUI

struct PlaylistDetailLoader: View {
    let playlistId: String
    let playlistSourceKey: String?
    let nowPlayingVM: NowPlayingViewModel
    @State private var playlist: Playlist?
    @State private var initialTracks: [Track]?
    @State private var initialArtworkImage: PlatformImage?
    @State private var isLoading = true
    @State private var error: Error?
    
    @Environment(\.dependencies) private var deps

    init(playlistId: String, playlistSourceKey: String? = nil, nowPlayingVM: NowPlayingViewModel) {
        self.playlistId = playlistId
        self.playlistSourceKey = playlistSourceKey
        self.nowPlayingVM = nowPlayingVM
    }
    
    var body: some View {
        Group {
            if let playlist = playlist {
                PlaylistDetailView(
                    playlist: playlist,
                    nowPlayingVM: nowPlayingVM,
                    initialTracks: initialTracks,
                    initialArtworkImage: initialArtworkImage
                )
            } else if isLoading {
                MediaDetailSurface<EmptyView>.LoadingState(title: "Loading playlist…")
            } else if let error = error {
                EnsembleStateScaffold(
                    kind: .error,
                    title: "Failed to load playlist",
                    message: error.localizedDescription
                )
            } else {
                EnsembleStateScaffold(kind: .empty, title: "Playlist not found")
            }
        }
        .task {
            await loadPlaylist()
        }
    }
    
    @MainActor
    private func loadPlaylist() async {
        do {
            guard let cdPlaylist = try await deps.playlistRepository.fetchPlaylist(
                ratingKey: playlistId,
                sourceCompositeKey: playlistSourceKey
            ) else {
                finishLoading(playlist: nil, initialTracks: nil, initialArtworkImage: nil, error: nil)
                return
            }

            let loadedPlaylist = Playlist(from: cdPlaylist)
            let loadedTracks = cdPlaylist.tracksArray.map { Track(from: $0) }
            let loadedArtworkImage = await loadCachedArtwork(for: loadedPlaylist)
            finishLoading(
                playlist: loadedPlaylist,
                // An incomplete membership list must be reloaded by the detail
                // view model so it can disable destructive playlist edits.
                initialTracks: cdPlaylist.hasUnavailableTracks || loadedTracks.isEmpty ? nil : loadedTracks,
                initialArtworkImage: loadedArtworkImage,
                error: nil
            )
        } catch {
            finishLoading(playlist: nil, initialTracks: nil, initialArtworkImage: nil, error: error)
        }
    }

    private func loadCachedArtwork(for playlist: Playlist) async -> PlatformImage? {
        let descriptor = ArtworkResolutionDescriptor(
            path: playlist.compositePath,
            sourceKey: playlist.sourceCompositeKey,
            ratingKey: playlist.id,
            fallbackPath: nil,
            fallbackRatingKey: nil,
            cacheHint: PersistentArtworkCacheHint(playlist: playlist),
            fallbackCacheHint: nil,
            size: 600,
            priority: .high
        )

        return await ArtworkImageResolver.locallyCachedImage(
            for: descriptor,
            artworkLoader: deps.artworkLoader
        )?.image
    }

    @MainActor
    private func finishLoading(
        playlist: Playlist?,
        initialTracks: [Track]?,
        initialArtworkImage: PlatformImage?,
        error: Error?
    ) {
        guard !Task.isCancelled else { return }

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            self.initialTracks = initialTracks
            self.initialArtworkImage = initialArtworkImage
            self.playlist = playlist
            self.error = error
            self.isLoading = false
        }
    }
}
