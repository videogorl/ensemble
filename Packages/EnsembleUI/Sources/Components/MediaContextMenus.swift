import EnsembleCore
import SwiftUI

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
        let isPinned = pinManager.isPinned(id: album.id)

        Button {
            withAlbumTracks(album) { tracks in
                nowPlayingVM.play(tracks: tracks)
            }
        } label: {
            MediaActionLabel(kind: .play)
        }

        Button {
            withAlbumTracks(album) { tracks in
                nowPlayingVM.shufflePlay(tracks: tracks)
            }
        } label: {
            MediaActionLabel(kind: .shuffle)
        }

        Button {
            withAlbumTracks(album) { tracks in
                nowPlayingVM.enableRadio(tracks: tracks)
            }
        } label: {
            MediaActionLabel(kind: .radio)
        }

        Divider()

        Button {
            withAlbumTracks(album) { tracks in
                nowPlayingVM.playNext(tracks)
            }
        } label: {
            MediaActionLabel(kind: .playNext)
        }

        Button {
            withAlbumTracks(album) { tracks in
                nowPlayingVM.playLast(tracks)
            }
        } label: {
            MediaActionLabel(kind: .playLast)
        }

        if let recentTarget = nowPlayingVM.lastPlaylistTarget {
            Button {
                addAlbumToRecentPlaylist(album, expectedTitle: recentTarget.title)
            } label: {
                MediaActionLabel(kind: .addToRecentPlaylist(recentTarget.title))
            }
        }

        Button {
            withAlbumTracks(album) { tracks in
                presentPlaylistPicker(tracks, "Add Album to Playlist")
            }
        } label: {
            MediaActionLabel(kind: .addToPlaylist)
        }

        Divider()

        if let artistId = album.artistRatingKey {
            Button {
                openArtist(artistId)
            } label: {
                MediaActionLabel(kind: .goToArtist)
            }
        }

        Button {
            ShareActions.shareAlbumLink(album, deps: deps)
        } label: {
            MediaActionLabel(kind: .shareLink)
        }

        Divider()

        Button {
            Task {
                await deps.offlineDownloadService.setAlbumDownloadEnabled(album, isEnabled: !isDownloaded)
            }
        } label: {
            MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
        }

        Button {
            if let customPinAction {
                customPinAction(isPinned)
            } else if isPinned {
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
            MediaActionLabel(kind: .pin(isPinned: isPinned))
        }

        if let onEditMetadata {
            Button {
                onEditMetadata()
            } label: {
                MediaActionLabel(kind: .editMetadata)
            }
        }

        if let onDelete {
            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                MediaActionLabel(kind: .deleteAlbum)
            }
        }
    }

    private func openArtist(_ artistId: String) {
        if let navigateToArtist {
            navigateToArtist(artistId)
            return
        }

        self.navigationCoordinator.push(.artist(id: artistId), in: self.navigationCoordinator.selectedTab)
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
                                title: "Can't add to \(expectedTitle)",
                                message: "This album isn't compatible with that playlist.",
                                dedupeKey: "\(toastNamespace)-recent-playlist-incompatible-\(album.id)"
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

        Button {
            withArtistTracks(artist) { tracks in
                nowPlayingVM.play(tracks: tracks)
            }
        } label: {
            MediaActionLabel(kind: .play)
        }

        Button {
            withArtistTracks(artist) { tracks in
                nowPlayingVM.shufflePlay(tracks: tracks)
            }
        } label: {
            MediaActionLabel(kind: .shuffle)
        }

        Button {
            withArtistTracks(artist) { tracks in
                nowPlayingVM.enableRadio(tracks: tracks)
            }
        } label: {
            MediaActionLabel(kind: .radio)
        }

        Button {
            Task {
                await deps.offlineDownloadService.setArtistDownloadEnabled(artist, isEnabled: !isDownloaded)
            }
        } label: {
            MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
        }

        let isPinned = pinManager.isPinned(id: artist.id)
        Button {
            if let customPinAction {
                customPinAction(isPinned)
            } else if isPinned {
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
            MediaActionLabel(kind: .pin(isPinned: isPinned))
        }

        if let onEditMetadata {
            Button {
                onEditMetadata()
            } label: {
                MediaActionLabel(kind: .editMetadata)
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
        if let cached = try? await deps.libraryRepository.fetchTracks(forArtist: artist.id),
           !cached.isEmpty {
            return cached.map { Track(from: $0) }
        }
        guard let sourceKey = artist.sourceCompositeKey else { return [] }
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

        Button {
            withPlaylistTracks(playlist) { tracks in
                nowPlayingVM.play(tracks: tracks)
            }
        } label: {
            MediaActionLabel(kind: .play)
        }

        Button {
            withPlaylistTracks(playlist) { tracks in
                nowPlayingVM.shufflePlay(tracks: tracks)
            }
        } label: {
            MediaActionLabel(kind: .shuffle)
        }

        Button {
            withPlaylistTracks(playlist) { tracks in
                nowPlayingVM.playNext(tracks)
            }
        } label: {
            MediaActionLabel(kind: .playNext)
        }

        Button {
            withPlaylistTracks(playlist) { tracks in
                nowPlayingVM.playLast(tracks)
            }
        } label: {
            MediaActionLabel(kind: .playLast)
        }

        Button {
            Task {
                await deps.offlineDownloadService.setPlaylistDownloadEnabled(playlist, isEnabled: !isDownloaded)
            }
        } label: {
            MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
        }

        let isPinned = pinManager.isPinned(id: playlist.id)
        Button {
            if let customPinAction {
                customPinAction(isPinned)
            } else if isPinned {
                pinManager.unpin(id: playlist.id)
            } else {
                pinManager.pin(
                    id: playlist.id,
                    sourceKey: playlist.sourceCompositeKey ?? "",
                    type: .playlist,
                    title: playlist.title
                )
            }
        } label: {
            MediaActionLabel(kind: .pin(isPinned: isPinned))
        }

        if !playlist.isSmart {
            if let onRename {
                Button {
                    onRename()
                } label: {
                    MediaActionLabel(kind: .rename)
                }
            }

            if let onEdit {
                Button {
                    onEdit()
                } label: {
                    MediaActionLabel(kind: .editPlaylist)
                }
            }

            if let onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    MediaActionLabel(kind: .deletePlaylist)
                }
            }
        }
    }

    private func withPlaylistTracks(_ playlist: Playlist, perform action: @escaping ([Track]) -> Void) {
        Task {
            let tracks = await resolveTracks(for: playlist)
            guard !tracks.isEmpty else {
                await MainActor.run {
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: "exclamationmark.triangle.fill",
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
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @Environment(\.dependencies) private var deps

    var body: some View {
        Button {
            withMergedTracks { tracks in
                nowPlayingVM.play(tracks: tracks)
            }
        } label: {
            MediaActionLabel(kind: .play)
        }

        Button {
            withMergedTracks { tracks in
                nowPlayingVM.shufflePlay(tracks: tracks)
            }
        } label: {
            MediaActionLabel(kind: .shuffle)
        }

        Button {
            withMergedTracks { tracks in
                nowPlayingVM.playNext(tracks)
            }
        } label: {
            MediaActionLabel(kind: .playNext)
        }

        Button {
            withMergedTracks { tracks in
                nowPlayingVM.playLast(tracks)
            }
        } label: {
            MediaActionLabel(kind: .playLast)
        }

        if isAnyConstituentDownloaded {
            Button {
                Task {
                    for playlist in displayPlaylist.playlists {
                        await deps.offlineDownloadService.setPlaylistDownloadEnabled(playlist, isEnabled: false)
                    }
                }
            } label: {
                MediaActionLabel(kind: .removeDownloads)
            }
        } else {
            Button {
                Task {
                    for playlist in displayPlaylist.playlists {
                        await deps.offlineDownloadService.setPlaylistDownloadEnabled(playlist, isEnabled: true)
                    }
                }
            } label: {
                MediaActionLabel(kind: .downloadAll)
            }
        }

        if !displayPlaylist.isSmart {
            if let onRename {
                Button {
                    onRename()
                } label: {
                    MediaActionLabel(kind: .renameAll)
                }
            }

            if let onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    MediaActionLabel(kind: .deleteAll)
                }
            }
        }
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
