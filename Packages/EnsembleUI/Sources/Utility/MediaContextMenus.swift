import EnsembleCore
import SwiftUI

/// Shared track actions used by standalone media cards, feed rows, mini player, and fallback queue rows.
struct TrackActionsContextMenu: View {
    let track: Track
    let nowPlayingVM: NowPlayingViewModel
    var context: MediaMenuContext = .search
    var recentPlaylistTarget: Playlist? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    var onGoToAlbum: (() -> Void)? = nil
    var onGoToArtist: (() -> Void)? = nil
    var onRemoveFromQueue: (() -> Void)? = nil
    var onRemoveFromPlaylist: (() -> Void)? = nil
    var onEditMetadata: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    var body: some View {
        let recentTitle = recentPlaylistTarget.map { target in
            PlaylistActionPresentationHost.recentPlaylistTitle(
                for: [track],
                target: target,
                nowPlayingVM: nowPlayingVM
            )
        } ?? PlaylistActionPresentationHost.recentPlaylistTitle(
            for: [track],
            nowPlayingVM: nowPlayingVM
        )

        SwiftUIMediaMenuRenderer(
            sections: MediaMenuCatalog.sections(
                for: .track,
                context: context,
                availability: MediaMenuAvailability(
                    hasRecentPlaylist: recentTitle != nil,
                    canAddToRecentPlaylist: recentTitle != nil,
                    canGoToAlbum: track.albumRatingKey != nil,
                    canGoToArtist: track.artistRatingKey != nil,
                    canShareLink: true,
                    canShareAudioFile: true,
                    canFavorite: true,
                    canDownload: false,
                    canPin: false,
                    canEditMetadata: onEditMetadata != nil,
                    canDelete: onDelete != nil,
                    canRename: false,
                    canEditPlaylist: false,
                    canRemoveFromPlaylist: onRemoveFromPlaylist != nil,
                    canRemoveFromQueue: onRemoveFromQueue != nil
                )
            ),
            state: MediaMenuState(
                recentPlaylistTitle: recentTitle,
                isFavorited: nowPlayingVM.isTrackFavorited(track),
                isShuffleEnabled: nowPlayingVM.isShuffleEnabled,
                repeatMode: nowPlayingVM.repeatMode
            ),
            handlers: MediaMenuHandlers(
                toggleShuffle: {
                    nowPlayingVM.toggleShuffle()
                },
                repeatAll: {
                    nowPlayingVM.setRepeatMode(.all)
                },
                repeatOne: {
                    nowPlayingVM.setRepeatMode(.one)
                },
                playNext: {
                    nowPlayingVM.playNext(track)
                },
                playLast: {
                    nowPlayingVM.playLast(track)
                },
                addToRecentPlaylist: {
                    if let recentPlaylistTarget {
                        PlaylistActionPresentationHost.addToRecentPlaylist(
                            [track],
                            target: recentPlaylistTarget,
                            nowPlayingVM: nowPlayingVM
                        )
                    } else {
                        PlaylistActionPresentationHost.addToRecentPlaylist([track], nowPlayingVM: nowPlayingVM)
                    }
                },
                addToPlaylist: onAddToPlaylist,
                goToAlbum: {
                    if let onGoToAlbum {
                        onGoToAlbum()
                    } else if let albumId = track.albumRatingKey {
                        navigationCoordinator.push(
                            .album(id: albumId, sourceKey: track.sourceCompositeKey),
                            in: navigationCoordinator.selectedTab
                        )
                    }
                },
                goToArtist: {
                    if let onGoToArtist {
                        onGoToArtist()
                    } else if let artistId = track.artistRatingKey {
                        navigationCoordinator.push(
                            .artist(id: artistId, sourceKey: track.sourceCompositeKey),
                            in: navigationCoordinator.selectedTab
                        )
                    }
                },
                editMetadata: onEditMetadata,
                favorite: {
                    Task {
                        await nowPlayingVM.setTrackFavorite(
                            !nowPlayingVM.isTrackFavorited(track),
                            for: track
                        )
                    }
                },
                shareLink: {
                    ShareActions.shareTrackLink(track, deps: deps)
                },
                shareAudioFile: {
                    ShareActions.shareTrackFile(track, deps: deps)
                },
                removeFromPlaylist: onRemoveFromPlaylist,
                removeFromQueue: onRemoveFromQueue,
                deleteTrack: onDelete
            )
        )
    }
}

/// Shared album actions used by album grids, search results, and pinned sidebar rows.
struct AlbumActionsContextMenu: View {
    let album: Album
    let nowPlayingVM: NowPlayingViewModel
    let presentPlaylistPicker: ([Track], String) -> Void
    var toastNamespace: String = "album-menu"
    var navigateToArtist: ((String) -> Void)? = nil
    var onEditMetadata: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var customPinAction: ((Bool) -> Void)? = nil

    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @ObservedObject private var pinManager = DependencyContainer.shared.pinManager

    var body: some View {
        let isDownloaded = deps.offlineDownloadService.isAlbumDownloadEnabled(album)
        let canDownload = DownloadCapabilityPolicy.canAttemptDownload(
            for: album.sourceCompositeKey,
            accountManager: deps.accountManager
        )
        let isPinned = pinManager.isPinned(id: album.id, sourceKey: album.sourceCompositeKey ?? "")
        let recentTarget = nowPlayingVM.lastPlaylistTarget
        let recentPlaylistTitle = recentTarget.flatMap { target in
            nowPlayingVM.compatibleTrackCount([album.sourceProbeTrack], forServerSourceKey: target.sourceCompositeKey) > 0
                ? target.title
                : nil
        }
        let addToRecentPlaylist: (() -> Void)? = recentPlaylistTitle.map { title in
            { addAlbumToRecentPlaylist(album, expectedTitle: title) }
        }
        let goToArtist: (() -> Void)? = album.artistRatingKey.map { artistId in
            { openArtist(artistId) }
        }

        SwiftUIMediaMenuRenderer(
            sections: MediaMenuCatalog.sections(
                for: .album,
                context: .library,
                availability: MediaMenuAvailability(
                    hasRecentPlaylist: recentPlaylistTitle != nil,
                    canAddToRecentPlaylist: addToRecentPlaylist != nil,
                    canGoToAlbum: false,
                    canGoToArtist: goToArtist != nil,
                    canShareLink: true,
                    canShareAudioFile: false,
                    canFavorite: false,
                    canDownload: canDownload,
                    canPin: true,
                    canEditMetadata: onEditMetadata != nil,
                    canDelete: onDelete != nil,
                    canRename: false,
                    canEditPlaylist: false,
                    canRemoveFromQueue: false
                )
            ),
            state: MediaMenuState(
                recentPlaylistTitle: recentPlaylistTitle,
                isDownloaded: isDownloaded,
                isPinned: isPinned
            ),
            handlers: MediaMenuHandlers(
                play: {
                    withAlbumTracks(album) { tracks in
                        nowPlayingVM.play(tracks: tracks)
                    }
                },
                shuffle: {
                    withAlbumTracks(album) { tracks in
                        nowPlayingVM.shufflePlay(tracks: tracks)
                    }
                },
                radio: {
                    withAlbumTracks(album) { tracks in
                        nowPlayingVM.enableRadio(tracks: tracks)
                    }
                },
                playNext: {
                    withAlbumTracks(album) { tracks in
                        nowPlayingVM.playNext(tracks)
                    }
                },
                playLast: {
                    withAlbumTracks(album) { tracks in
                        nowPlayingVM.playLast(tracks)
                    }
                },
                addToRecentPlaylist: addToRecentPlaylist,
                addToPlaylist: {
                    withAlbumTracks(album) { tracks in
                        presentPlaylistPicker(tracks, "Add Album to Playlist")
                    }
                },
                goToArtist: goToArtist,
                editMetadata: onEditMetadata,
                download: {
                    Task {
                        await deps.downloadMutationWorkflow.setAlbumDownloadEnabled(album, isEnabled: !isDownloaded)
                    }
                },
                pin: {
                    if let customPinAction {
                        customPinAction(isPinned)
                    } else {
                        deps.pinMutationWorkflow.togglePin(
                            id: album.id,
                            sourceKey: album.sourceCompositeKey ?? "",
                            type: .album,
                            title: album.title,
                            isPinned: isPinned
                        )
                    }
                },
                shareLink: {
                    ShareActions.shareAlbumLink(album, deps: deps)
                },
                deleteAlbum: onDelete
            )
        )
    }

    private func openArtist(_ artistId: String) {
        if let navigateToArtist {
            navigateToArtist(artistId)
            return
        }

        navigationCoordinator.push(
            .artist(id: artistId, sourceKey: album.sourceCompositeKey),
            in: navigationCoordinator.selectedTab
        )
    }

    private func withAlbumTracks(_ album: Album, perform action: @escaping ([Track]) -> Void) {
        Task {
            let tracks = await resolveTracks(for: album)
            guard !tracks.isEmpty else {
                await MainActor.run {
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: EnsembleDesign.Icon.error,
                            title: "No tracks available",
                            message: "Try again after the album finishes loading.",
                            dedupeKey: "\(toastNamespace)-empty-\(album.id)"
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
        guard let sourceKey = album.sourceCompositeKey else { return [] }
        if let cached = try? await deps.libraryRepository.fetchTracks(forAlbum: album.id, sourceCompositeKey: sourceKey),
           !cached.isEmpty
        {
            return cached.map { Track(from: $0) }
        }
        return (try? await deps.syncCoordinator.getAlbumTracks(albumId: album.id, sourceKey: sourceKey)) ?? []
    }

    private func addAlbumToRecentPlaylist(_ album: Album, expectedTitle: String) {
        withAlbumTracks(album) { tracks in
            Task {
                guard let playlist = await PlaylistActionPresentationHost.resolveRecentPlaylistTarget(
                    for: tracks,
                    nowPlayingVM: nowPlayingVM
                ) else {
                    await MainActor.run {
                        deps.toastCenter.show(
                            ToastPayload(
                                style: .warning,
                                iconSystemName: EnsembleDesign.Icon.error,
                                title: "Can't add to \(expectedTitle)",
                                message: "This album isn't compatible with that playlist.",
                                dedupeKey: "\(toastNamespace)-recent-playlist-incompatible-\(album.id)"
                            )
                        )
                    }
                    return
                }

                PlaylistActionPresentationHost.addToRecentPlaylist(
                    tracks,
                    target: playlist,
                    nowPlayingVM: nowPlayingVM
                )
            }
        }
    }
}

/// Shared artist actions used by artist grids, search results, and pinned sidebar rows.
struct ArtistActionsContextMenu: View {
    let artist: Artist
    let nowPlayingVM: NowPlayingViewModel
    var toastNamespace: String = "artist-menu"
    var onEditMetadata: (() -> Void)? = nil
    var customPinAction: ((Bool) -> Void)? = nil

    @Environment(\.dependencies) private var deps
    @ObservedObject private var pinManager = DependencyContainer.shared.pinManager

    var body: some View {
        let isDownloaded = deps.offlineDownloadService.isArtistDownloadEnabled(artist)
        let canDownload = DownloadCapabilityPolicy.canAttemptDownload(
            for: artist.sourceCompositeKey,
            accountManager: deps.accountManager
        )
        let isPinned = pinManager.isPinned(id: artist.id, sourceKey: artist.sourceCompositeKey ?? "")

        SwiftUIMediaMenuRenderer(
            sections: MediaMenuCatalog.sections(
                for: .artist,
                context: .library,
                availability: MediaMenuAvailability(
                    hasRecentPlaylist: false,
                    canAddToRecentPlaylist: false,
                    canGoToAlbum: false,
                    canGoToArtist: false,
                    canShareLink: false,
                    canShareAudioFile: false,
                    canFavorite: false,
                    canDownload: canDownload,
                    canPin: true,
                    canEditMetadata: onEditMetadata != nil,
                    canDelete: false,
                    canRename: false,
                    canEditPlaylist: false,
                    canRemoveFromQueue: false
                )
            ),
            state: MediaMenuState(
                isDownloaded: isDownloaded,
                isPinned: isPinned
            ),
            handlers: MediaMenuHandlers(
                play: {
                    withArtistTracks(artist) { tracks in
                        nowPlayingVM.play(tracks: tracks)
                    }
                },
                shuffle: {
                    withArtistTracks(artist) { tracks in
                        nowPlayingVM.shufflePlay(tracks: tracks)
                    }
                },
                radio: {
                    withArtistTracks(artist) { tracks in
                        nowPlayingVM.enableRadio(tracks: tracks)
                    }
                },
                editMetadata: onEditMetadata,
                download: {
                    Task {
                        await deps.downloadMutationWorkflow.setArtistDownloadEnabled(artist, isEnabled: !isDownloaded)
                    }
                },
                pin: {
                    if let customPinAction {
                        customPinAction(isPinned)
                    } else {
                        deps.pinMutationWorkflow.togglePin(
                            id: artist.id,
                            sourceKey: artist.sourceCompositeKey ?? "",
                            type: .artist,
                            title: artist.name,
                            isPinned: isPinned
                        )
                    }
                }
            )
        )
    }

    private func withArtistTracks(_ artist: Artist, perform action: @escaping ([Track]) -> Void) {
        Task {
            let tracks = await resolveTracks(for: artist)
            guard !tracks.isEmpty else {
                await MainActor.run {
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: EnsembleDesign.Icon.error,
                            title: "No tracks available",
                            message: "Try again after the artist finishes loading.",
                            dedupeKey: "\(toastNamespace)-empty-\(artist.id)"
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
        guard let sourceKey = artist.sourceCompositeKey else { return [] }
        if let cached = try? await deps.libraryRepository.fetchTracks(forArtist: artist.id, sourceCompositeKey: sourceKey),
           !cached.isEmpty
        {
            return cached.map { Track(from: $0) }
        }
        return (try? await deps.syncCoordinator.getArtistTracks(artistId: artist.id, sourceKey: sourceKey)) ?? []
    }
}

/// Shared playlist actions used by playlist lists, search results, and pinned sidebar rows.
struct PlaylistActionsContextMenu: View {
    let playlist: Playlist
    let nowPlayingVM: NowPlayingViewModel
    var toastNamespace: String = "playlist-menu"
    var onRename: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var customPinAction: ((Bool) -> Void)? = nil

    @Environment(\.dependencies) private var deps
    @ObservedObject private var pinManager = DependencyContainer.shared.pinManager

    var body: some View {
        let isDownloaded = deps.offlineDownloadService.isPlaylistDownloadEnabled(playlist)
        let canDownload = DownloadCapabilityPolicy.canAttemptDownload(
            for: playlist.sourceCompositeKey,
            accountManager: deps.accountManager
        )
        let isPinned = pinManager.isPinned(id: playlist.id, sourceKey: playlist.sourceCompositeKey ?? "")

        SwiftUIMediaMenuRenderer(
            sections: MediaMenuCatalog.sections(
                for: .playlist(isSmart: playlist.isSmart),
                context: .library,
                availability: MediaMenuAvailability(
                    hasRecentPlaylist: false,
                    canAddToRecentPlaylist: false,
                    canGoToAlbum: false,
                    canGoToArtist: false,
                    canShareLink: false,
                    canShareAudioFile: false,
                    canFavorite: false,
                    canDownload: canDownload,
                    canPin: true,
                    canEditMetadata: false,
                    canDelete: onDelete != nil,
                    canRename: onRename != nil,
                    canEditPlaylist: onEdit != nil,
                    canRemoveFromQueue: false
                )
            ),
            state: MediaMenuState(
                isDownloaded: isDownloaded,
                isPinned: isPinned
            ),
            handlers: MediaMenuHandlers(
                play: {
                    withPlaylistTracks(playlist) { tracks in
                        nowPlayingVM.play(tracks: tracks)
                    }
                },
                shuffle: {
                    withPlaylistTracks(playlist) { tracks in
                        nowPlayingVM.shufflePlay(tracks: tracks)
                    }
                },
                playNext: {
                    withPlaylistTracks(playlist) { tracks in
                        nowPlayingVM.playNext(tracks)
                    }
                },
                playLast: {
                    withPlaylistTracks(playlist) { tracks in
                        nowPlayingVM.playLast(tracks)
                    }
                },
                rename: onRename,
                editPlaylist: onEdit,
                download: {
                    Task {
                        await deps.downloadMutationWorkflow.setPlaylistDownloadEnabled(playlist, isEnabled: !isDownloaded)
                    }
                },
                pin: {
                    if let customPinAction {
                        customPinAction(isPinned)
                    } else {
                        deps.pinMutationWorkflow.togglePin(
                            id: playlist.id,
                            sourceKey: playlist.sourceCompositeKey ?? "",
                            type: .playlist,
                            title: playlist.title,
                            isPinned: isPinned
                        )
                    }
                },
                deletePlaylist: onDelete
            )
        )
    }

    private func withPlaylistTracks(_ playlist: Playlist, perform action: @escaping ([Track]) -> Void) {
        Task {
            let tracks = await resolveTracks(for: playlist)
            guard !tracks.isEmpty else {
                await MainActor.run {
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: EnsembleDesign.Icon.error,
                            title: "No tracks available",
                            message: "Try again after this playlist finishes syncing.",
                            dedupeKey: "\(toastNamespace)-empty-\(playlist.id)"
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

    private func resolveTracks(for playlist: Playlist) async -> [Track] {
        if let cachedPlaylist = try? await deps.playlistRepository.fetchPlaylist(
            ratingKey: playlist.id,
            sourceCompositeKey: playlist.sourceCompositeKey
        ) {
            return cachedPlaylist.tracksArray.map { Track(from: $0) }
        }
        return []
    }
}

/// Shared merged-playlist actions used by playlist lists and pinned sidebar rows.
struct MergedPlaylistActionsContextMenu: View {
    let displayPlaylist: DisplayPlaylist
    let nowPlayingVM: NowPlayingViewModel
    var toastNamespace: String = "merged-playlist-menu"
    var context: MediaMenuContext = .library
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onUnpinAll: (() -> Void)? = nil

    @Environment(\.dependencies) private var deps

    var body: some View {
        let downloadablePlaylists = displayPlaylist.playlists.filter {
            DownloadCapabilityPolicy.canAttemptDownload(
                for: $0.sourceCompositeKey,
                accountManager: deps.accountManager
            )
        }
        let isDownloaded = isAnyConstituentDownloaded
        let downloadAll: (() -> Void)? = isDownloaded ? nil : {
            Task {
                for playlist in downloadablePlaylists {
                    await deps.downloadMutationWorkflow.setPlaylistDownloadEnabled(playlist, isEnabled: true)
                }
            }
        }
        let removeDownloads: (() -> Void)? = isDownloaded ? {
            Task {
                for playlist in displayPlaylist.playlists {
                    await deps.downloadMutationWorkflow.setPlaylistDownloadEnabled(playlist, isEnabled: false)
                }
            }
        } : nil

        SwiftUIMediaMenuRenderer(
            sections: MediaMenuCatalog.sections(
                for: .mergedPlaylist(isSmart: displayPlaylist.isSmart),
                context: context,
                availability: MediaMenuAvailability(
                    hasRecentPlaylist: false,
                    canAddToRecentPlaylist: false,
                    canGoToAlbum: false,
                    canGoToArtist: false,
                    canShareLink: false,
                    canShareAudioFile: false,
                    canFavorite: false,
                    canDownload: !downloadablePlaylists.isEmpty,
                    canPin: false,
                    canEditMetadata: false,
                    canDelete: onDelete != nil,
                    canRename: onRename != nil,
                    canEditPlaylist: false,
                    canRemoveFromQueue: false
                )
            ),
            state: MediaMenuState(isDownloaded: isDownloaded),
            handlers: MediaMenuHandlers(
                play: {
                    withMergedTracks { tracks in
                        nowPlayingVM.play(tracks: tracks)
                    }
                },
                shuffle: {
                    withMergedTracks { tracks in
                        nowPlayingVM.shufflePlay(tracks: tracks)
                    }
                },
                playNext: {
                    withMergedTracks { tracks in
                        nowPlayingVM.playNext(tracks)
                    }
                },
                playLast: {
                    withMergedTracks { tracks in
                        nowPlayingVM.playLast(tracks)
                    }
                },
                renameAll: onRename,
                downloadAll: downloadAll,
                removeDownloads: removeDownloads,
                unpinAll: onUnpinAll,
                deleteAll: onDelete
            )
        )
    }

    private var isAnyConstituentDownloaded: Bool {
        displayPlaylist.playlists.contains { deps.offlineDownloadService.isPlaylistDownloadEnabled($0) }
    }

    private func withMergedTracks(perform action: @escaping ([Track]) -> Void) {
        Task {
            var trackSets: [[Track]] = []
            for playlist in displayPlaylist.playlists {
                if let cached = try? await deps.playlistRepository.fetchPlaylist(
                    ratingKey: playlist.id,
                    sourceCompositeKey: playlist.sourceCompositeKey
                ) {
                    trackSets.append(cached.tracksArray.map { Track(from: $0) })
                }
            }
            let interleaved = DisplayPlaylist.interleave(trackSets)
            guard !interleaved.isEmpty else {
                await MainActor.run {
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: "exclamationmark.triangle.fill",
                            title: "No tracks available",
                            message: "Try again after playlists finish syncing.",
                            dedupeKey: "\(toastNamespace)-empty-\(displayPlaylist.id)"
                        )
                    )
                }
                return
            }
            await MainActor.run {
                action(interleaved)
            }
        }
    }
}

private extension Album {
    var sourceProbeTrack: Track {
        Track(
            id: id,
            key: key,
            title: title,
            artistName: artistName,
            albumRatingKey: id,
            artistRatingKey: artistRatingKey,
            thumbPath: thumbPath,
            sourceCompositeKey: sourceCompositeKey
        )
    }
}
