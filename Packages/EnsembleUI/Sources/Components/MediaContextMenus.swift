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
                presentPlaylistPicker(tracks, "Add Album to Playlist")
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
                openArtist(artistId)
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

        Button {
            ShareActions.shareAlbumLink(album, deps: deps)
        } label: {
            Label("Share Link…", systemImage: "link")
        }

        let isPinned = pinManager.isPinned(id: album.id)
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
            Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin.fill")
        }

        if let onEditMetadata {
            Button {
                onEditMetadata()
            } label: {
                Label("Edit Metadata…", systemImage: "pencil")
            }
        }

        if let onDelete {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Album", systemImage: "trash")
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
                systemImage: isDownloaded ? "xmark.circle" : "arrow.down.circle"
            )
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
            Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin.fill")
        }

        if let onEditMetadata {
            Button {
                onEditMetadata()
            } label: {
                Label("Edit Metadata…", systemImage: "pencil")
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
            Label("Play", systemImage: "play.fill")
        }

        Button {
            withPlaylistTracks(playlist) { tracks in
                nowPlayingVM.shufflePlay(tracks: tracks)
            }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            withPlaylistTracks(playlist) { tracks in
                nowPlayingVM.playNext(tracks)
            }
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            withPlaylistTracks(playlist) { tracks in
                nowPlayingVM.playLast(tracks)
            }
        } label: {
            Label("Play Last", systemImage: "text.append")
        }

        Button {
            Task {
                await deps.offlineDownloadService.setPlaylistDownloadEnabled(playlist, isEnabled: !isDownloaded)
            }
        } label: {
            Label(
                isDownloaded ? "Remove Download" : "Download",
                systemImage: isDownloaded ? "xmark.circle" : "arrow.down.circle"
            )
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
            Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin.fill")
        }

        if !playlist.isSmart {
            if let onRename {
                Button {
                    onRename()
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
            }

            if let onEdit {
                Button {
                    onEdit()
                } label: {
                    Label("Edit Playlist", systemImage: "slider.horizontal.3")
                }
            }

            if let onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Playlist", systemImage: "trash")
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
            Label("Play", systemImage: "play.fill")
        }

        Button {
            withMergedTracks { tracks in
                nowPlayingVM.shufflePlay(tracks: tracks)
            }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            withMergedTracks { tracks in
                nowPlayingVM.playNext(tracks)
            }
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            withMergedTracks { tracks in
                nowPlayingVM.playLast(tracks)
            }
        } label: {
            Label("Play Last", systemImage: "text.append")
        }

        if isAnyConstituentDownloaded {
            Button {
                Task {
                    for playlist in displayPlaylist.playlists {
                        await deps.offlineDownloadService.setPlaylistDownloadEnabled(playlist, isEnabled: false)
                    }
                }
            } label: {
                Label("Remove Downloads", systemImage: "xmark.circle")
            }
        } else {
            Button {
                Task {
                    for playlist in displayPlaylist.playlists {
                        await deps.offlineDownloadService.setPlaylistDownloadEnabled(playlist, isEnabled: true)
                    }
                }
            } label: {
                Label("Download All", systemImage: "arrow.down.circle")
            }
        }

        if !displayPlaylist.isSmart {
            if let onRename {
                Button {
                    onRename()
                } label: {
                    Label("Rename All...", systemImage: "pencil")
                }
            }

            if let onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete All", systemImage: "trash")
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
