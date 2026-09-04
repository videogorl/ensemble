import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

struct MediaSourceActionChoice: Identifiable {
    let id: String
    let title: String
    let source: String
    var availability: MusicItemActionAvailability = .available
    let action: () -> Void
}

struct MediaSourceActionRequest: Identifiable {
    let id = UUID()
    let title: String
    let choices: [MediaSourceActionChoice]
}

@MainActor
final class MediaSourceActionPresenter: ObservableObject {
    @Published var pendingRequest: MediaSourceActionRequest?
    private var selectedAction: (() -> Void)?

    func present(title: String, choices: [MediaSourceActionChoice]) {
        guard choices.contains(where: { $0.availability.isAvailable }) else { return }
        if choices.count == 1, choices[0].availability.isAvailable {
            choices[0].action()
        } else {
            pendingRequest = MediaSourceActionRequest(title: title, choices: choices)
        }
    }

    func choose(_ choice: MediaSourceActionChoice) {
        guard choice.availability.isAvailable else { return }
        selectedAction = choice.action
        pendingRequest = nil
    }

    func completeSelection() {
        let action = selectedAction
        selectedAction = nil
        action?()
    }

    func cancel() {
        selectedAction = nil
        pendingRequest = nil
    }
}

func resolvedDownloadMenuAvailability(
    isDownloaded: Bool,
    sourceAvailability: MusicItemActionAvailability
) -> MusicItemActionAvailability {
    isDownloaded ? .available : sourceAvailability
}

/// Shared track actions used by standalone media cards, feed rows, mini player, and fallback queue rows.
struct TrackActionsContextMenu: View {
    let track: Track
    var sourceTracks: [Track] = []
    let nowPlayingVM: NowPlayingViewModel
    var context: MediaMenuContext = .search
    var onAddToPlaylist: ((Track) -> Void)? = nil
    var onGoToAlbum: (() -> Void)? = nil
    var onGoToArtist: (() -> Void)? = nil
    var onGetInfo: (() -> Void)? = nil
    var onRemoveFromQueue: (() -> Void)? = nil
    var onRemoveFromPlaylist: (() -> Void)? = nil
    var onEditMetadata: ((Track) -> Void)? = nil
    var onDelete: ((Track) -> Void)? = nil

    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var sourceActionPresenter: MediaSourceActionPresenter
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    private var mutationTracks: [Track] {
        sourceTracks.isEmpty ? [track] : sourceTracks
    }

    var body: some View {
        let hiddenIdentity = trackHiddenIdentity
        let hiddenCandidates = mutationTracks.compactMap { $0.hiddenCandidate(deps: deps) }
        let isHidden = hiddenMediaIsHidden(
            identity: hiddenIdentity,
            candidates: hiddenCandidates,
            store: deps.hiddenMediaStore
        )
        let isFavorited = nowPlayingVM.isTrackFavorited(track)
        let favoriteAvailability = MusicItemActionAvailability.combined(mutationTracks.map {
            $0.actionAvailability(for: .favorite, isFavorited: nowPlayingVM.isTrackFavorited($0))
        })
        let editAvailability = MusicItemActionAvailability.combined(
            mutationTracks.map { $0.actionAvailability(for: .editMetadata) }
        )
        let deleteAvailability = MusicItemActionAvailability.combined(
            mutationTracks.map { $0.actionAvailability(for: .delete) }
        )
        let recentTitle = PlaylistActionPresentationHost.recentPlaylistTitle(
            for: [track],
            nowPlayingVM: nowPlayingVM
        )

        SwiftUIMediaMenuRenderer(
            sections: MediaMenuCatalog.sections(
                for: .track,
                context: context,
                availability: MediaMenuAvailability(
                    hasRecentPlaylist: recentTitle != nil,
                    canAddToLibrary: mutationTracks.contains(where: nowPlayingVM.canAddTrackToLibrary),
                    canAddToRecentPlaylist: recentTitle != nil,
                    canGoToAlbum: track.albumRatingKey != nil,
                    canGoToArtist: track.artistRatingKey != nil,
                    canGetInfo: onGetInfo != nil,
                    canShareLink: true,
                    canShareAudioFile: track.sourceCapabilities.supportsAudioFileSharing,
                    canFavorite: true,
                    canDownload: false,
                    canPin: false,
                    canEditMetadata: onEditMetadata != nil,
                    canDelete: onDelete != nil,
                    canRename: false,
                    canEditPlaylist: false,
                    canRemoveFromPlaylist: onRemoveFromPlaylist != nil,
                    canRemoveFromQueue: onRemoveFromQueue != nil,
                    itemActions: [
                        .favorite: favoriteAvailability,
                        .editMetadata: editAvailability,
                        .deleteTrack: deleteAvailability
                    ]
                )
            ),
            state: MediaMenuState(
                recentPlaylistTitle: recentTitle,
                isFavorited: isFavorited,
                isHidden: isHidden,
                hideRequiresSourceSelection: hiddenMediaRequiresSourceSelection(
                    identity: hiddenIdentity,
                    candidates: hiddenCandidates,
                    store: deps.hiddenMediaStore
                ),
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
                addToLibrary: sourceMutationAction(
                    title: "Add Song to Library",
                    tracks: mutationTracks.filter(nowPlayingVM.canAddTrackToLibrary),
                    presenter: sourceActionPresenter,
                    deps: deps
                ) { selectedTrack in
                    Task { await nowPlayingVM.addTrackToLibrary(selectedTrack) }
                },
                addToRecentPlaylist: {
                    PlaylistActionPresentationHost.addToRecentPlaylist([track], nowPlayingVM: nowPlayingVM)
                },
                addToPlaylist: onAddToPlaylist.flatMap { callback in
                    sourceMutationAction(
                        title: "Add Song to Playlist",
                        tracks: mutationTracks,
                        presenter: sourceActionPresenter,
                        deps: deps,
                        action: callback
                    )
                },
                goToAlbum: {
                    if let onGoToAlbum {
                        onGoToAlbum()
                    } else if let albumId = track.albumRatingKey {
                        navigationCoordinator.routeFromMenu(
                            to: .album(id: albumId, sourceKey: track.sourceCompositeKey),
                            in: navigationCoordinator.selectedTab
                        )
                    }
                },
                goToArtist: {
                    if let onGoToArtist {
                        onGoToArtist()
                    } else if let artistId = track.artistRatingKey {
                        navigationCoordinator.routeFromMenu(
                            to: .artist(id: artistId, sourceKey: track.sourceCompositeKey),
                            in: navigationCoordinator.selectedTab
                        )
                    }
                },
                getInfo: onGetInfo,
                editMetadata: onEditMetadata.flatMap { callback in
                    sourceMutationAction(
                        title: "Edit Song Metadata",
                        tracks: mutationTracks.filter {
                            $0.actionAvailability(for: .editMetadata).isAvailable
                        },
                        presenter: sourceActionPresenter,
                        deps: deps,
                        action: callback
                    )
                },
                favorite: sourceMutationAction(
                    title: isFavorited ? "Unfavorite Song" : "Favorite Song",
                    tracks: mutationTracks.filter {
                        $0.actionAvailability(
                            for: .favorite,
                            isFavorited: nowPlayingVM.isTrackFavorited($0)
                        ).isAvailable
                    },
                    presenter: sourceActionPresenter,
                    deps: deps
                ) { selectedTrack in
                    Task {
                        await nowPlayingVM.setTrackFavorite(
                            !isFavorited,
                            for: selectedTrack
                        )
                    }
                },
                shareEnsembleLink: {
                    ShareActions.shareEnsembleLink(track, deps: deps)
                },
                shareLink: {
                    ShareActions.shareTrackLink(track, deps: deps)
                },
                shareAudioFile: {
                    ShareActions.shareTrackFile(track, deps: deps)
                },
                removeFromPlaylist: onRemoveFromPlaylist,
                removeFromQueue: onRemoveFromQueue,
                deleteTrack: onDelete.flatMap { callback in
                    sourceMutationAction(
                        title: "Delete Song",
                        tracks: mutationTracks.filter {
                            $0.actionAvailability(for: .delete).isAvailable
                        },
                        presenter: sourceActionPresenter,
                        deps: deps,
                        action: callback
                    )
                },
                toggleHidden: hiddenMediaToggleAction(
                    identity: hiddenIdentity,
                    candidates: hiddenCandidates,
                    store: deps.hiddenMediaStore,
                    presenter: sourceActionPresenter
                )
            )
        )
    }

    private var trackHiddenIdentity: HiddenMediaIdentity? {
        track.hiddenIdentity(deps: deps)
    }
}

/// Shared album actions used by album grids, search results, and pinned sidebar rows.
struct AlbumActionsContextMenu: View {
    let album: Album
    var sourceAlbums: [Album] = []
    let nowPlayingVM: NowPlayingViewModel
    var presentPlaylistPicker: (([Track], String) -> Void)? = nil
    var toastNamespace: String = "album-menu"
    var navigateToArtist: ((String) -> Void)? = nil
    var onGetInfo: (() -> Void)? = nil
    var onEditMetadata: ((Album) -> Void)? = nil
    var onDelete: ((Album) -> Void)? = nil
    var customPinAction: ((Bool) -> Void)? = nil
    var customIsPinned: (() -> Bool)? = nil

    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var sourceActionPresenter: MediaSourceActionPresenter
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    private let pinManager = DependencyContainer.shared.pinManager

    private var mutationAlbums: [Album] {
        sourceAlbums.isEmpty ? [album] : sourceAlbums
    }

    var body: some View {
        let hiddenIdentity = HiddenMediaIdentity(album)
        let hiddenCandidates = mutationAlbums.compactMap { $0.hiddenCandidate(deps: deps) }
        let isHidden = hiddenMediaIsHidden(
            identity: hiddenIdentity,
            candidates: hiddenCandidates,
            store: deps.hiddenMediaStore
        )
        let downloadState = deps.downloadMutationWorkflow.batchState(for: mutationAlbums)
        let isDownloaded = downloadState.isEnabled
        let downloadAvailability = MusicItemActionAvailability.combined(
            mutationAlbums.map {
                resolvedDownloadMenuAvailability(
                    isDownloaded: deps.offlineDownloadService.isAlbumDownloadEnabled($0),
                    sourceAvailability: $0.actionAvailability(for: .download)
                )
            }
        )
        let editAvailability = MusicItemActionAvailability.combined(
            mutationAlbums.map { $0.actionAvailability(for: .editMetadata) }
        )
        let deleteAvailability = MusicItemActionAvailability.combined(
            mutationAlbums.map { $0.actionAvailability(for: .delete) }
        )
        let isPinned = customIsPinned?()
            ?? pinManager.isPinned(id: album.id, sourceKey: album.sourceCompositeKey ?? "")
        let recentTarget = nowPlayingVM.lastPlaylistTarget(for: [album.sourceProbeTrack])
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
                    canGetInfo: onGetInfo != nil,
                    canShareLink: true,
                    canShareAudioFile: false,
                    canFavorite: false,
                    canDownload: true,
                    canPin: true,
                    canEditMetadata: onEditMetadata != nil,
                    canDelete: onDelete != nil,
                    canRename: false,
                    canEditPlaylist: false,
                    canRemoveFromQueue: false,
                    itemActions: [
                        .download: downloadAvailability,
                        .editMetadata: editAvailability,
                        .deleteAlbum: deleteAvailability
                    ]
                )
            ),
            state: MediaMenuState(
                recentPlaylistTitle: recentPlaylistTitle,
                isDownloaded: isDownloaded,
                isPinned: isPinned,
                isHidden: isHidden,
                hideRequiresSourceSelection: hiddenMediaRequiresSourceSelection(
                    identity: hiddenIdentity,
                    candidates: hiddenCandidates,
                    store: deps.hiddenMediaStore
                )
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
                addToPlaylist: presentPlaylistPicker.flatMap { present in
                    sourceMutationAction(
                        title: "Add Album to Playlist",
                        items: mutationAlbums,
                        id: \.sourceScopedID,
                        itemTitle: \.title,
                        sourceKey: \.sourceCompositeKey,
                        presenter: sourceActionPresenter,
                        deps: deps
                    ) { selectedAlbum in
                        withAlbumTracks(selectedAlbum) { tracks in
                            present(tracks, "Add Album to Playlist")
                        }
                    }
                },
                goToArtist: goToArtist,
                getInfo: onGetInfo,
                editMetadata: onEditMetadata.flatMap { callback in
                    sourceMutationAction(
                        title: "Edit Album Metadata",
                        items: mutationAlbums,
                        id: \.sourceScopedID,
                        itemTitle: \.title,
                        sourceKey: \.sourceCompositeKey,
                        availability: { $0.actionAvailability(for: .editMetadata) },
                        presenter: sourceActionPresenter,
                        deps: deps,
                        action: callback
                    )
                },
                download: {
                    Task {
                        await deps.downloadMutationWorkflow.toggleDownloads(for: mutationAlbums)
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
                shareEnsembleLink: {
                    ShareActions.shareEnsembleLink(album, deps: deps)
                },
                shareLink: {
                    ShareActions.shareAlbumLink(album, deps: deps)
                },
                deleteAlbum: onDelete.flatMap { callback in
                    sourceMutationAction(
                        title: "Delete Album",
                        items: mutationAlbums.filter {
                            $0.actionAvailability(for: .delete).isAvailable
                        },
                        id: \.sourceScopedID,
                        itemTitle: \.title,
                        sourceKey: \.sourceCompositeKey,
                        presenter: sourceActionPresenter,
                        deps: deps,
                        action: callback
                    )
                },
                toggleHidden: hiddenMediaToggleAction(
                    identity: hiddenIdentity,
                    candidates: hiddenCandidates,
                    store: deps.hiddenMediaStore,
                    presenter: sourceActionPresenter
                )
            )
        )
    }

    private func openArtist(_ artistId: String) {
        if let navigateToArtist {
            navigateToArtist(artistId)
            return
        }

        navigationCoordinator.routeFromMenu(
            to: .artist(id: artistId, sourceKey: album.sourceCompositeKey),
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
    var sourceArtists: [Artist] = []
    let nowPlayingVM: NowPlayingViewModel
    var toastNamespace: String = "artist-menu"
    var onEditMetadata: ((Artist) -> Void)? = nil
    var customPinAction: ((Bool) -> Void)? = nil
    var customIsPinned: (() -> Bool)? = nil

    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var sourceActionPresenter: MediaSourceActionPresenter
    private let pinManager = DependencyContainer.shared.pinManager

    private var mutationArtists: [Artist] {
        sourceArtists.isEmpty ? [artist] : sourceArtists
    }

    var body: some View {
        let hiddenIdentity = HiddenMediaIdentity(artist)
        let hiddenCandidates = mutationArtists.compactMap { $0.hiddenCandidate(deps: deps) }
        let isHidden = hiddenMediaIsHidden(
            identity: hiddenIdentity,
            candidates: hiddenCandidates,
            store: deps.hiddenMediaStore
        )
        let downloadState = deps.downloadMutationWorkflow.batchState(for: mutationArtists)
        let isDownloaded = downloadState.isEnabled
        let downloadAvailability = MusicItemActionAvailability.combined(
            mutationArtists.map {
                resolvedDownloadMenuAvailability(
                    isDownloaded: deps.offlineDownloadService.isArtistDownloadEnabled($0),
                    sourceAvailability: $0.actionAvailability(for: .download)
                )
            }
        )
        let editAvailability = MusicItemActionAvailability.combined(
            mutationArtists.map { $0.actionAvailability(for: .editMetadata) }
        )
        let isPinned = customIsPinned?()
            ?? pinManager.isPinned(id: artist.id, sourceKey: artist.sourceCompositeKey ?? "")

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
                    canDownload: true,
                    canPin: true,
                    canEditMetadata: onEditMetadata != nil,
                    canDelete: false,
                    canRename: false,
                    canEditPlaylist: false,
                    canRemoveFromQueue: false,
                    itemActions: [
                        .download: downloadAvailability,
                        .editMetadata: editAvailability
                    ]
                )
            ),
            state: MediaMenuState(
                isDownloaded: isDownloaded,
                isPinned: isPinned,
                isHidden: isHidden,
                hideRequiresSourceSelection: hiddenMediaRequiresSourceSelection(
                    identity: hiddenIdentity,
                    candidates: hiddenCandidates,
                    store: deps.hiddenMediaStore
                )
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
                editMetadata: onEditMetadata.flatMap { callback in
                    sourceMutationAction(
                        title: "Edit Artist Metadata",
                        items: mutationArtists.filter {
                            $0.actionAvailability(for: .editMetadata).isAvailable
                        },
                        id: \.sourceScopedID,
                        itemTitle: \.name,
                        sourceKey: \.sourceCompositeKey,
                        presenter: sourceActionPresenter,
                        deps: deps,
                        action: callback
                    )
                },
                download: {
                    Task {
                        await deps.downloadMutationWorkflow.toggleDownloads(for: mutationArtists)
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
                },
                shareEnsembleLink: {
                    ShareActions.shareEnsembleLink(artist, deps: deps)
                },
                toggleHidden: hiddenMediaToggleAction(
                    identity: hiddenIdentity,
                    candidates: hiddenCandidates,
                    store: deps.hiddenMediaStore,
                    presenter: sourceActionPresenter
                )
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

struct MergedArtistHiddenContextMenu: View {
    let displayArtist: DisplayArtist
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var sourceActionPresenter: MediaSourceActionPresenter

    @ViewBuilder
    var body: some View {
        let candidates = displayArtist.artists.compactMap { $0.hiddenCandidate(deps: deps) }
        let isHidden = hiddenMediaIsHidden(
            identity: nil,
            candidates: candidates,
            store: deps.hiddenMediaStore
        )
        if let action = hiddenMediaToggleAction(
            candidates: candidates,
            store: deps.hiddenMediaStore,
            presenter: sourceActionPresenter
        ) {
            Button(action: action) {
                MediaActionLabel(
                    kind: .toggleHidden(
                        isHidden: isHidden,
                        requiresSourceSelection: hiddenMediaRequiresSourceSelection(
                            candidates: candidates,
                            store: deps.hiddenMediaStore
                        )
                    )
                )
            }
        }
    }
}

@MainActor
func hiddenMediaToggleAction(
    identity: HiddenMediaIdentity? = nil,
    candidates: [HiddenMediaCandidate],
    store: HiddenMediaStore,
    presenter: MediaSourceActionPresenter
) -> (() -> Void)? {
    let isHidden = hiddenMediaIsHidden(identity: identity, candidates: candidates, store: store)
    let eligible = candidates.filter { store.snapshot.contains($0.identity) == isHidden }
    if eligible.isEmpty, let identity {
        return { store.setHidden(!isHidden, identity: identity) }
    }
    guard !eligible.isEmpty else { return nil }
    return {
        var choices = eligible.map { candidate in
            MediaSourceActionChoice(
                id: candidate.id,
                title: candidate.title,
                source: candidate.source
            ) {
                store.setHidden(
                    !isHidden,
                    identity: candidate.identity,
                    relatedCatalogID: candidate.relatedCatalogID
                )
            }
        }
        if eligible.count > 1 {
            choices.insert(
                MediaSourceActionChoice(
                    id: "all-sources",
                    title: "All Sources",
                    source: "\(eligible.count) sources"
                ) {
                    store.setHidden(!isHidden, candidates: eligible)
                },
                at: 0
            )
        }
        presenter.present(
            title: isHidden ? "Unhide Item" : "Hide Item",
            choices: choices
        )
    }
}

@MainActor
func hiddenMediaRequiresSourceSelection(
    identity: HiddenMediaIdentity? = nil,
    candidates: [HiddenMediaCandidate],
    store: HiddenMediaStore
) -> Bool {
    let isHidden = hiddenMediaIsHidden(identity: identity, candidates: candidates, store: store)
    return candidates.lazy.filter { store.snapshot.contains($0.identity) == isHidden }.count > 1
}

@MainActor
func hiddenMediaIsHidden(
    identity: HiddenMediaIdentity?,
    candidates: [HiddenMediaCandidate],
    store: HiddenMediaStore
) -> Bool {
    if candidates.count > 1 {
        return candidates.allSatisfy { store.snapshot.contains($0.identity) }
    }
    if let identity { return store.snapshot.contains(identity) }
    return candidates.first.map { store.snapshot.contains($0.identity) } ?? false
}

struct HiddenMediaDetailMenuButton: View {
    let candidates: [HiddenMediaCandidate]
    let identity: HiddenMediaIdentity?

    @ObservedObject private var hiddenMediaStore = DependencyContainer.shared.hiddenMediaStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sourceActionPresenter: MediaSourceActionPresenter
    @State private var requestedHideIdentities: Set<HiddenMediaIdentity> = []

    @ViewBuilder
    var body: some View {
        Group {
            if let action = hiddenMediaToggleAction(
                identity: identity,
                candidates: candidates,
                store: hiddenMediaStore,
                presenter: sourceActionPresenter
            ) {
                let isHidden = hiddenMediaIsHidden(
                    identity: identity,
                    candidates: candidates,
                    store: hiddenMediaStore
                )
                Button {
                    if !isHidden {
                        requestedHideIdentities = Set(
                            candidates.lazy
                                .map(\.identity)
                                .filter { !hiddenMediaStore.snapshot.contains($0) }
                        )
                    }
                    action()
                    dismissAfterHideIfNeeded()
                } label: {
                    MediaActionLabel(
                        kind: .toggleHidden(
                            isHidden: isHidden,
                            requiresSourceSelection: hiddenMediaRequiresSourceSelection(
                                identity: identity,
                                candidates: candidates,
                                store: hiddenMediaStore
                            )
                        )
                    )
                }
            }
        }
        .onChange(of: hiddenMediaStore.snapshot) { _ in
            dismissAfterHideIfNeeded()
        }
    }

    private func dismissAfterHideIfNeeded() {
        guard !requestedHideIdentities.isEmpty,
              requestedHideIdentities.isSubset(of: hiddenMediaStore.snapshot.identities) else { return }
        requestedHideIdentities.removeAll()
        dismiss()
    }
}

/// Shared playlist actions used by playlist lists, search results, and pinned sidebar rows.
struct PlaylistActionsContextMenu: View {
    let playlist: Playlist
    var sourcePlaylists: [Playlist] = []
    let nowPlayingVM: NowPlayingViewModel
    var toastNamespace: String = "playlist-menu"
    var onGetInfo: (() -> Void)? = nil
    var onRename: ((Playlist) -> Void)? = nil
    var onEdit: ((Playlist) -> Void)? = nil
    var onDelete: ((Playlist) -> Void)? = nil
    var customPinAction: ((Bool) -> Void)? = nil

    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var sourceActionPresenter: MediaSourceActionPresenter
    private let pinManager = DependencyContainer.shared.pinManager

    private var mutationPlaylists: [Playlist] {
        sourcePlaylists.isEmpty ? [playlist] : sourcePlaylists
    }

    var body: some View {
        let hiddenIdentity = HiddenMediaIdentity(playlist)
        let hiddenCandidates = mutationPlaylists.compactMap { $0.hiddenCandidate(deps: deps) }
        let isHidden = hiddenMediaIsHidden(
            identity: hiddenIdentity,
            candidates: hiddenCandidates,
            store: deps.hiddenMediaStore
        )
        let downloadState = deps.downloadMutationWorkflow.batchState(for: mutationPlaylists)
        let isDownloaded = downloadState.isEnabled
        let downloadAvailability = MusicItemActionAvailability.combined(
            mutationPlaylists.map {
                resolvedDownloadMenuAvailability(
                    isDownloaded: deps.offlineDownloadService.isPlaylistDownloadEnabled($0),
                    sourceAvailability: $0.actionAvailability(for: .download)
                )
            }
        )
        let renameAvailability = MusicItemActionAvailability.combined(
            mutationPlaylists.map { $0.actionAvailability(for: .rename) }
        )
        let reorderAvailability = MusicItemActionAvailability.combined(
            mutationPlaylists.map { $0.actionAvailability(for: .reorder) }
        )
        let deleteAvailability = MusicItemActionAvailability.combined(
            mutationPlaylists.map { $0.actionAvailability(for: .delete) }
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
                    canGetInfo: onGetInfo != nil,
                    canShareLink: false,
                    canShareAudioFile: false,
                    canFavorite: false,
                    canDownload: true,
                    canPin: true,
                    canEditMetadata: false,
                    canDelete: onDelete != nil,
                    canRename: onRename != nil,
                    canEditPlaylist: onEdit != nil,
                    canRemoveFromQueue: false,
                    itemActions: [
                        .download: downloadAvailability,
                        .rename: renameAvailability,
                        .editPlaylist: reorderAvailability,
                        .deletePlaylist: deleteAvailability
                    ]
                )
            ),
            state: MediaMenuState(
                isDownloaded: isDownloaded,
                isPinned: isPinned,
                isHidden: isHidden,
                hideRequiresSourceSelection: hiddenMediaRequiresSourceSelection(
                    identity: hiddenIdentity,
                    candidates: hiddenCandidates,
                    store: deps.hiddenMediaStore
                )
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
                getInfo: onGetInfo,
                rename: onRename.flatMap { callback in
                    sourceMutationAction(
                        title: "Rename Playlist",
                        items: mutationPlaylists.filter {
                            $0.actionAvailability(for: .rename).isAvailable
                        },
                        id: \.sourceScopedID,
                        itemTitle: \.title,
                        sourceKey: \.sourceCompositeKey,
                        presenter: sourceActionPresenter,
                        deps: deps,
                        action: callback
                    )
                },
                editPlaylist: onEdit.flatMap { callback in
                    sourceMutationAction(
                        title: "Edit Playlist",
                        items: mutationPlaylists.filter {
                            $0.actionAvailability(for: .reorder).isAvailable
                        },
                        id: \.sourceScopedID,
                        itemTitle: \.title,
                        sourceKey: \.sourceCompositeKey,
                        presenter: sourceActionPresenter,
                        deps: deps,
                        action: callback
                    )
                },
                download: {
                    Task {
                        await deps.downloadMutationWorkflow.toggleDownloads(for: mutationPlaylists)
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
                shareEnsembleLink: {
                    ShareActions.shareEnsembleLink(playlist, deps: deps)
                },
                deletePlaylist: onDelete.flatMap { callback in
                    sourceMutationAction(
                        title: "Delete Playlist",
                        items: mutationPlaylists.filter {
                            $0.actionAvailability(for: .delete).isAvailable
                        },
                        id: \.sourceScopedID,
                        itemTitle: \.title,
                        sourceKey: \.sourceCompositeKey,
                        presenter: sourceActionPresenter,
                        deps: deps,
                        action: callback
                    )
                },
                toggleHidden: hiddenMediaToggleAction(
                    identity: hiddenIdentity,
                    candidates: hiddenCandidates,
                    store: deps.hiddenMediaStore,
                    presenter: sourceActionPresenter
                )
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
        (try? await DisplayPlaylist.resolvedTracks(
            for: [playlist],
            using: deps.playlistRepository
        )) ?? []
    }
}

/// Shared merged-playlist actions used by playlist lists and pinned sidebar rows.
struct MergedPlaylistActionsContextMenu: View {
    let displayPlaylist: DisplayPlaylist
    let nowPlayingVM: NowPlayingViewModel
    var toastNamespace: String = "merged-playlist-menu"
    var context: MediaMenuContext = .library
    var onRename: (([Playlist]) -> Void)? = nil
    var onDelete: ((Playlist) -> Void)? = nil
    var onUnpinAll: (() -> Void)? = nil

    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var sourceActionPresenter: MediaSourceActionPresenter

    var body: some View {
        let candidates = displayPlaylist.playlists.compactMap { $0.hiddenCandidate(deps: deps) }
        let downloadAvailability = MusicItemActionAvailability.combined(
            displayPlaylist.playlists.map { playlist in
                resolvedDownloadMenuAvailability(
                    isDownloaded: deps.offlineDownloadService.isPlaylistDownloadEnabled(playlist),
                    sourceAvailability: playlist.actionAvailability(for: .download)
                )
            }
        )
        let renameAvailability = MusicItemActionAvailability.combined(
            displayPlaylist.playlists.map { $0.actionAvailability(for: .rename) }
        )
        let deleteAvailability = MusicItemActionAvailability.combined(
            displayPlaylist.playlists.map { $0.actionAvailability(for: .delete) }
        )
        let isDownloaded = deps.downloadMutationWorkflow.batchState(
            for: displayPlaylist.playlists
        ).isEnabled
        let isHidden = hiddenMediaIsHidden(
            identity: nil,
            candidates: candidates,
            store: deps.hiddenMediaStore
        )
        let isPinned = displayPlaylist.playlists.allSatisfy {
            deps.pinMutationWorkflow.isPinned(id: $0.id, sourceKey: $0.sourceCompositeKey ?? "")
        }

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
                    canDownload: true,
                    canPin: true,
                    canEditMetadata: false,
                    canDelete: onDelete != nil,
                    canRename: onRename != nil,
                    canEditPlaylist: false,
                    canRemoveFromQueue: false,
                    itemActions: [
                        .download: downloadAvailability,
                        .rename: renameAvailability,
                        .deletePlaylist: deleteAvailability
                    ]
                )
            ),
            state: MediaMenuState(
                isDownloaded: isDownloaded,
                isPinned: isPinned,
                isHidden: isHidden,
                hideRequiresSourceSelection: hiddenMediaRequiresSourceSelection(
                    candidates: candidates,
                    store: deps.hiddenMediaStore
                )
            ),
            handlers: MediaMenuHandlers(
                play: {
                    withPreferredTracks { tracks in
                        nowPlayingVM.play(tracks: tracks)
                    }
                },
                shuffle: {
                    withPreferredTracks { tracks in
                        nowPlayingVM.shufflePlay(tracks: tracks)
                    }
                },
                playNext: {
                    withPreferredTracks { tracks in
                        nowPlayingVM.playNext(tracks)
                    }
                },
                playLast: {
                    withPreferredTracks { tracks in
                        nowPlayingVM.playLast(tracks)
                    }
                },
                rename: onRename.flatMap { callback in
                    sourceMutationAction(
                        title: "Rename Playlist",
                        items: displayPlaylist.editablePlaylists,
                        id: \.sourceScopedID,
                        itemTitle: \.title,
                        sourceKey: \.sourceCompositeKey,
                        allAction: callback,
                        presenter: sourceActionPresenter,
                        deps: deps,
                        action: { callback([$0]) }
                    )
                },
                download: {
                    Task {
                        await deps.downloadMutationWorkflow.toggleDownloads(
                            for: displayPlaylist.playlists
                        )
                    }
                },
                pin: {
                    if isPinned {
                        if let onUnpinAll {
                            onUnpinAll()
                        } else {
                            deps.pinMutationWorkflow.unpinAll(
                                identities: Set(displayPlaylist.playlists.map(\.sourceScopedID))
                            )
                        }
                    } else {
                        deps.pinMutationWorkflow.pinAll(items: displayPlaylist.playlists.map { playlist in
                            (id: playlist.id, sourceKey: playlist.sourceCompositeKey ?? "", type: .playlist, title: displayPlaylist.title)
                        })
                    }
                },
                unpinAll: onUnpinAll,
                shareEnsembleLink: {
                    ShareActions.shareEnsembleLink(displayPlaylist, deps: deps)
                },
                deletePlaylist: onDelete.flatMap { callback in
                    sourceMutationAction(
                        title: "Delete Playlist",
                        items: displayPlaylist.deletablePlaylists,
                        id: \.sourceScopedID,
                        itemTitle: \.title,
                        sourceKey: \.sourceCompositeKey,
                        presenter: sourceActionPresenter,
                        deps: deps,
                        action: callback
                    )
                },
                toggleHidden: hiddenMediaToggleAction(
                    candidates: candidates,
                    store: deps.hiddenMediaStore,
                    presenter: sourceActionPresenter
                )
            )
        )
    }

    private func withPreferredTracks(perform action: @escaping ([Track]) -> Void) {
        Task {
            let tracks = (try? await DisplayPlaylist.resolvedTracks(
                for: [displayPlaylist.primaryPlaylist],
                using: deps.playlistRepository
            )) ?? []
            guard !tracks.isEmpty else {
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
                action(tracks)
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

@MainActor
func mediaSourceDescription(_ sourceKey: String, deps: DependencyContainer) -> String {
    guard let source = deps.accountManager.sourcePresentation(for: sourceKey) else { return sourceKey }
    return "\(source.serverName) · \(source.libraryName) · \(source.accountName)"
}

@MainActor
func sourceMutationAction<Item>(
    title: String,
    items: [Item],
    id: (Item) -> String,
    itemTitle: (Item) -> String,
    sourceKey: (Item) -> String?,
    availability: ((Item) -> MusicItemActionAvailability)? = nil,
    allAction: (([Item]) -> Void)? = nil,
    presenter: MediaSourceActionPresenter,
    deps: DependencyContainer,
    action: @escaping (Item) -> Void
) -> (() -> Void)? {
    var choices = items.compactMap { item -> MediaSourceActionChoice? in
        guard let sourceKey = sourceKey(item) else { return nil }
        return MediaSourceActionChoice(
            id: id(item),
            title: itemTitle(item),
            source: mediaSourceDescription(sourceKey, deps: deps),
            availability: availability?(item) ?? .available
        ) {
            action(item)
        }
    }
    if items.count > 1, let allAction {
        choices.insert(
            MediaSourceActionChoice(
                id: "all-sources",
                title: "All Sources",
                source: "\(items.count) sources"
            ) {
                allAction(items)
            },
            at: 0
        )
    }
    guard choices.contains(where: { $0.availability.isAvailable }) else { return nil }
    return { presenter.present(title: title, choices: choices) }
}

@MainActor
func sourceMutationAction(
    title: String,
    tracks: [Track],
    allAction: (([Track]) -> Void)? = nil,
    presenter: MediaSourceActionPresenter,
    deps: DependencyContainer,
    action: @escaping (Track) -> Void
) -> (() -> Void)? {
    sourceMutationAction(
        title: title,
        items: tracks,
        id: \.sourceScopedID,
        itemTitle: \.title,
        sourceKey: \.sourceCompositeKey,
        allAction: allAction,
        presenter: presenter,
        deps: deps,
        action: action
    )
}

extension Track {
    @MainActor
    func hiddenIdentity(deps: DependencyContainer) -> HiddenMediaIdentity? {
        guard let sourceKey = sourceCompositeKey else { return nil }
        if let identity = HiddenMediaIdentity(self), deps.hiddenMediaStore.snapshot.contains(identity) {
            return identity
        }
        guard key == "apple-catalog", let catalogID = appleMusicCatalogID else { return nil }
        return deps.hiddenMediaStore.hiddenLibraryIdentity(catalogID: catalogID, sourceKey: sourceKey)
    }

    @MainActor
    func hiddenCandidate(deps: DependencyContainer) -> HiddenMediaCandidate? {
        guard key != "apple-catalog", let identity = HiddenMediaIdentity(self) else { return nil }
        return HiddenMediaCandidate(
            identity: identity,
            title: title,
            source: mediaSourceDescription(identity.sourceCompositeKey, deps: deps),
            relatedCatalogID: appleMusicCatalogID
        )
    }

    @MainActor
    func hiddenToggleAction(deps: DependencyContainer) -> (() -> Void)? {
        if let identity = hiddenIdentity(deps: deps) {
            return { deps.hiddenMediaStore.setHidden(false, identity: identity) }
        }
        guard let candidate = hiddenCandidate(deps: deps) else { return nil }
        return {
            deps.hiddenMediaStore.setHidden(
                true,
                identity: candidate.identity,
                relatedCatalogID: candidate.relatedCatalogID
            )
        }
    }
}

extension Album {
    @MainActor
    func hiddenCandidate(deps: DependencyContainer) -> HiddenMediaCandidate? {
        guard let identity = HiddenMediaIdentity(self) else { return nil }
        return HiddenMediaCandidate(
            identity: identity,
            title: title,
            source: mediaSourceDescription(identity.sourceCompositeKey, deps: deps)
        )
    }
}

extension Artist {
    @MainActor
    func hiddenCandidate(deps: DependencyContainer) -> HiddenMediaCandidate? {
        guard let identity = HiddenMediaIdentity(self) else { return nil }
        return HiddenMediaCandidate(
            identity: identity,
            title: name,
            source: mediaSourceDescription(identity.sourceCompositeKey, deps: deps)
        )
    }
}

extension Playlist {
    @MainActor
    func hiddenCandidate(deps: DependencyContainer) -> HiddenMediaCandidate? {
        guard let identity = HiddenMediaIdentity(self) else { return nil }
        return HiddenMediaCandidate(
            identity: identity,
            title: title,
            source: mediaSourceDescription(identity.sourceCompositeKey, deps: deps)
        )
    }
}
