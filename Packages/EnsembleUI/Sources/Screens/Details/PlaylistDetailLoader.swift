import EnsembleCore
import SwiftUI

struct PlaylistDetailLoader: View {
    let playlistId: String
    let playlistSourceKey: String?
    let nowPlayingVM: NowPlayingViewModel
    @State private var playlist: Playlist?
    @State private var initialTracks: [Track]?
    @State private var initialItems: [PlaylistItem]?
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
                    initialItems: initialItems,
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
            #if os(macOS)
            guard let cdPlaylist = try await deps.playlistRepository.fetchPlaylist(
                ratingKey: playlistId,
                sourceCompositeKey: playlistSourceKey
            ) else {
                finishLoading(playlist: nil, initialTracks: nil, initialItems: nil, initialArtworkImage: nil, error: nil)
                return
            }
            let loadedItems: [PlaylistItem]? = cdPlaylist.playlistItemsArray.map(PlaylistItem.init(from:))
            #else
            guard let cdPlaylist = try await deps.playlistRepository.fetchPlaylistHeader(
                ratingKey: playlistId,
                sourceCompositeKey: playlistSourceKey
            ) else {
                finishLoading(playlist: nil, initialTracks: nil, initialItems: nil, initialArtworkImage: nil, error: nil)
                return
            }
            let loadedItems: [PlaylistItem]? = nil
            #endif

            let loadedPlaylist = Playlist(from: cdPlaylist)
            let loadedArtworkImage = await loadCachedArtwork(for: loadedPlaylist)
            finishLoading(
                playlist: loadedPlaylist,
                initialTracks: loadedItems?.map(\.track),
                initialItems: loadedItems,
                initialArtworkImage: loadedArtworkImage,
                error: nil
            )
        } catch {
            finishLoading(playlist: nil, initialTracks: nil, initialItems: nil, initialArtworkImage: nil, error: error)
        }
    }

    private func loadCachedArtwork(for playlist: Playlist) async -> PlatformImage? {
        let hasCompositeArtwork = playlist.compositePath?.isEmpty == false
        let fallbackSourceKey = playlist.fallbackArtworkSourceCompositeKey
            ?? playlist.sourceCompositeKey
        let descriptor = ArtworkResolutionDescriptor(
            path: playlist.compositePath,
            sourceKey: hasCompositeArtwork ? playlist.sourceCompositeKey : fallbackSourceKey,
            ratingKey: playlist.id,
            fallbackPath: playlist.fallbackArtworkPath,
            fallbackRatingKey: playlist.fallbackArtworkRatingKey,
            fallbackSourceKey: fallbackSourceKey,
            cacheHint: PersistentArtworkCacheHint(playlist: playlist),
            fallbackCacheHint: PersistentArtworkCacheHint(
                ratingKey: playlist.fallbackArtworkRatingKey,
                kind: .album,
                sourcePath: playlist.fallbackArtworkPath,
                sourceCompositeKey: fallbackSourceKey
            ),
            size: ArtworkSize.detail.requestPixelDimension,
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
        initialItems: [PlaylistItem]?,
        initialArtworkImage: PlatformImage?,
        error: Error?
    ) {
        guard !Task.isCancelled else { return }

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            self.initialTracks = initialTracks
            self.initialItems = initialItems
            self.initialArtworkImage = initialArtworkImage
            self.playlist = playlist
            self.error = error
            self.isLoading = false
        }
    }
}
