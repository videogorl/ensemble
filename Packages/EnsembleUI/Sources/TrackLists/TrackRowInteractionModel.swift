import EnsembleCore

/// Resolves per-track row actions so SwiftUI and UIKit lists share the same
/// menu availability, favorite state, and recent-playlist gating logic.
public struct TrackRowInteractionModel {
    public struct ResolvedActions {
        public let onPlayNext: (() -> Void)?
        public let onPlayLast: (() -> Void)?
        public let onAddToLibrary: (() -> Void)?
        public let onAddToPlaylist: (() -> Void)?
        public let onAddToRecentPlaylist: (() -> Void)?
        public let onToggleFavorite: (() -> Void)?
        public let onGoToAlbum: (() -> Void)?
        public let onGoToArtist: (() -> Void)?
        public let onGetInfo: (() -> Void)?
        public let onEditMetadata: (() -> Void)?
        public let onShareEnsembleLink: (() -> Void)?
        public let onShareLink: (() -> Void)?
        public let onShareFile: (() -> Void)?
        public let onDeleteTrack: (() -> Void)?
        public let onToggleHidden: (() -> Void)?
        public let isFavorited: Bool
        public let isHidden: Bool
        public let hideRequiresSourceSelection: Bool
        public let recentPlaylistTitle: String?
        public let favoriteAvailability: MusicItemActionAvailability
        public let editMetadataAvailability: MusicItemActionAvailability
        public let deleteAvailability: MusicItemActionAvailability

        public var hasContextMenu: Bool {
            onPlayNext != nil ||
            onPlayLast != nil ||
            onAddToLibrary != nil ||
            onAddToPlaylist != nil ||
            onAddToRecentPlaylist != nil ||
            onToggleFavorite != nil ||
            onGoToAlbum != nil ||
            onGoToArtist != nil ||
            onGetInfo != nil ||
            onEditMetadata != nil ||
            onShareEnsembleLink != nil ||
            onShareLink != nil ||
            onShareFile != nil ||
            onDeleteTrack != nil ||
            onToggleHidden != nil
        }
    }

    public let onPlayNext: ((Track) -> Void)?
    public let onPlayLast: ((Track) -> Void)?
    public let onAddToLibrary: ((Track) -> Void)?
    public let onAddToPlaylist: ((Track) -> Void)?
    public let onAddToRecentPlaylist: ((Track) -> Void)?
    public let onToggleFavorite: ((Track) -> Void)?
    public let onGoToAlbum: ((Track) -> Void)?
    public let onGoToArtist: ((Track) -> Void)?
    public let onGetInfo: ((Track) -> Void)?
    public let onEditMetadata: ((Track) -> Void)?
    public let onShareEnsembleLink: ((Track) -> Void)?
    public let onShareLink: ((Track) -> Void)?
    public let onShareFile: ((Track) -> Void)?
    public let onDeleteTrack: ((Track) -> Void)?
    public let onToggleHidden: ((Track) -> Void)?
    public let isTrackFavorited: ((Track) -> Bool)?
    public let isTrackHidden: ((Track) -> Bool)?
    public let canToggleHidden: ((Track) -> Bool)?
    public let canAddToLibrary: ((Track) -> Bool)?
    public let canAddToRecentPlaylist: ((Track) -> Bool)?
    public let canRemoveFromPlaylist: ((Track) -> Bool)?
    public let recentPlaylistTitle: String?
    public let recentPlaylistTitleForTrack: ((Track) -> String?)?
    public let mutationCandidates: ((Track) -> [Track])?
    public let onSelectMutationSource: ((String, [Track], (([Track]) -> Void)?, @escaping (Track) -> Void) -> Void)?

    public init(
        onPlayNext: ((Track) -> Void)? = nil,
        onPlayLast: ((Track) -> Void)? = nil,
        onAddToLibrary: ((Track) -> Void)? = nil,
        onAddToPlaylist: ((Track) -> Void)? = nil,
        onAddToRecentPlaylist: ((Track) -> Void)? = nil,
        onToggleFavorite: ((Track) -> Void)? = nil,
        onGoToAlbum: ((Track) -> Void)? = nil,
        onGoToArtist: ((Track) -> Void)? = nil,
        onGetInfo: ((Track) -> Void)? = nil,
        onEditMetadata: ((Track) -> Void)? = nil,
        onShareEnsembleLink: ((Track) -> Void)? = nil,
        onShareLink: ((Track) -> Void)? = nil,
        onShareFile: ((Track) -> Void)? = nil,
        onDeleteTrack: ((Track) -> Void)? = nil,
        onToggleHidden: ((Track) -> Void)? = nil,
        isTrackFavorited: ((Track) -> Bool)? = nil,
        isTrackHidden: ((Track) -> Bool)? = nil,
        canToggleHidden: ((Track) -> Bool)? = nil,
        canAddToLibrary: ((Track) -> Bool)? = nil,
        canAddToRecentPlaylist: ((Track) -> Bool)? = nil,
        canRemoveFromPlaylist: ((Track) -> Bool)? = nil,
        recentPlaylistTitle: String? = nil,
        recentPlaylistTitleForTrack: ((Track) -> String?)? = nil,
        mutationCandidates: ((Track) -> [Track])? = nil,
        onSelectMutationSource: ((String, [Track], (([Track]) -> Void)?, @escaping (Track) -> Void) -> Void)? = nil
    ) {
        self.onPlayNext = onPlayNext
        self.onPlayLast = onPlayLast
        self.onAddToLibrary = onAddToLibrary
        self.onAddToPlaylist = onAddToPlaylist
        self.onAddToRecentPlaylist = onAddToRecentPlaylist
        self.onToggleFavorite = onToggleFavorite
        self.onGoToAlbum = onGoToAlbum
        self.onGoToArtist = onGoToArtist
        self.onGetInfo = onGetInfo
        self.onEditMetadata = onEditMetadata
        self.onShareEnsembleLink = onShareEnsembleLink
        self.onShareLink = onShareLink
        self.onShareFile = onShareFile
        self.onDeleteTrack = onDeleteTrack
        self.onToggleHidden = onToggleHidden
        self.isTrackFavorited = isTrackFavorited
        self.isTrackHidden = isTrackHidden
        self.canToggleHidden = canToggleHidden
        self.canAddToLibrary = canAddToLibrary
        self.canAddToRecentPlaylist = canAddToRecentPlaylist
        self.canRemoveFromPlaylist = canRemoveFromPlaylist
        self.recentPlaylistTitle = recentPlaylistTitle
        self.recentPlaylistTitleForTrack = recentPlaylistTitleForTrack
        self.mutationCandidates = mutationCandidates
        self.onSelectMutationSource = onSelectMutationSource
    }

    public func isFavorited(_ track: Track) -> Bool {
        isTrackFavorited?(track) ?? track.isFavorite
    }

    public func allowsRemovalFromPlaylist(_ track: Track) -> Bool {
        canRemoveFromPlaylist?(track) ?? true
    }

    public func canAddTrackToLibrary(_ track: Track) -> Bool {
        track.canAddToSourceLibrary && (canAddToLibrary?(track) ?? true)
    }

    public func hasContextMenu(for track: Track) -> Bool {
        guard track.isLibraryAvailable else { return false }
        let allowRecentPlaylist = onAddToRecentPlaylist != nil && (canAddToRecentPlaylist?(track) ?? true)

        return onPlayNext != nil ||
            onPlayLast != nil ||
            (canAddTrackToLibrary(track) && onAddToLibrary != nil) ||
            onAddToPlaylist != nil ||
            allowRecentPlaylist ||
            onToggleFavorite != nil ||
            onGoToAlbum != nil ||
            onGoToArtist != nil ||
            onGetInfo != nil ||
            onEditMetadata != nil ||
            onShareEnsembleLink != nil ||
            onShareLink != nil ||
            onShareFile != nil ||
            onDeleteTrack != nil ||
            ((canToggleHidden?(track) ?? true) && onToggleHidden != nil)
    }

    func hasHandler(for action: TrackSwipeAction) -> Bool {
        switch action {
        case .playNext:
            return onPlayNext != nil
        case .playLast:
            return onPlayLast != nil
        case .addToPlaylist:
            return onAddToPlaylist != nil
        case .favoriteToggle:
            return onToggleFavorite != nil
        }
    }

    public func resolve(for track: Track) -> ResolvedActions {
        guard track.isLibraryAvailable else {
            return ResolvedActions(
                onPlayNext: nil,
                onPlayLast: nil,
                onAddToLibrary: nil,
                onAddToPlaylist: nil,
                onAddToRecentPlaylist: nil,
                onToggleFavorite: nil,
                onGoToAlbum: nil,
                onGoToArtist: nil,
                onGetInfo: nil,
                onEditMetadata: nil,
                onShareEnsembleLink: nil,
                onShareLink: nil,
                onShareFile: nil,
                onDeleteTrack: nil,
                onToggleHidden: nil,
                isFavorited: false,
                isHidden: false,
                hideRequiresSourceSelection: false,
                recentPlaylistTitle: nil,
                favoriteAvailability: .unavailable(reason: track.unavailableReason ?? "This track is unavailable."),
                editMetadataAvailability: .unavailable(reason: track.unavailableReason ?? "This track is unavailable."),
                deleteAvailability: .unavailable(reason: track.unavailableReason ?? "This track is unavailable.")
            )
        }
        let allowRecentPlaylist = onAddToRecentPlaylist != nil && (canAddToRecentPlaylist?(track) ?? true)
        let isFavorited = isFavorited(track)
        let candidates = mutationCandidates?(track) ?? [track]
        let addToLibraryCandidates = candidates.filter(canAddTrackToLibrary)
        let favoriteCandidates = candidates.filter {
            $0.actionAvailability(for: .favorite, isFavorited: self.isFavorited($0)).isAvailable
        }
        let editCandidates = candidates.filter {
            $0.actionAvailability(for: .editMetadata).isAvailable
        }
        let deleteCandidates = candidates.filter {
            $0.actionAvailability(for: .delete).isAvailable
        }
        let hiddenCandidates = candidates.filter { canToggleHidden?($0) ?? true }

        return ResolvedActions(
            onPlayNext: onPlayNext.map { callback in { callback(track) } },
            onPlayLast: onPlayLast.map { callback in { callback(track) } },
            onAddToLibrary: mutationAction(
                title: "Add Song to Library",
                candidates: addToLibraryCandidates,
                callback: onAddToLibrary
            ),
            onAddToPlaylist: mutationAction(
                title: "Add Song to Playlist",
                candidates: candidates,
                callback: onAddToPlaylist
            ),
            onAddToRecentPlaylist: allowRecentPlaylist ? onAddToRecentPlaylist.map { callback in { callback(track) } } : nil,
            onToggleFavorite: mutationAction(
                title: isFavorited ? "Unfavorite Song" : "Favorite Song",
                candidates: favoriteCandidates.isEmpty ? candidates : favoriteCandidates,
                callback: onToggleFavorite
            ),
            onGoToAlbum: onGoToAlbum.map { callback in { callback(track) } },
            onGoToArtist: onGoToArtist.map { callback in { callback(track) } },
            onGetInfo: onGetInfo.map { callback in { callback(track) } },
            onEditMetadata: mutationAction(
                title: "Edit Song Metadata",
                candidates: editCandidates.isEmpty ? candidates : editCandidates,
                callback: onEditMetadata
            ),
            onShareEnsembleLink: onShareEnsembleLink.map { callback in { callback(track) } },
            onShareLink: onShareLink.map { callback in { callback(track) } },
            onShareFile: track.sourceCapabilities.supportsAudioFileSharing ? onShareFile.map { callback in { callback(track) } } : nil,
            onDeleteTrack: mutationAction(
                title: "Delete Song",
                candidates: deleteCandidates.isEmpty ? candidates : deleteCandidates,
                callback: onDeleteTrack
            ),
            onToggleHidden: mutationAction(
                title: "Hide Song",
                candidates: hiddenCandidates,
                callback: onToggleHidden,
                allAction: onToggleHidden.map { callback in
                    { tracks in tracks.forEach(callback) }
                }
            ),
            isFavorited: isFavorited,
            isHidden: isTrackHidden?(track) ?? false,
            hideRequiresSourceSelection: hiddenCandidates.count > 1,
            recentPlaylistTitle: allowRecentPlaylist
                ? recentPlaylistTitleForTrack?(track) ?? recentPlaylistTitle
                : nil,
            favoriteAvailability: .combined(candidates.map {
                $0.actionAvailability(for: .favorite, isFavorited: self.isFavorited($0))
            }),
            editMetadataAvailability: .combined(candidates.map {
                $0.actionAvailability(for: .editMetadata)
            }),
            deleteAvailability: .combined(candidates.map {
                $0.actionAvailability(for: .delete)
            })
        )
    }

    private func mutationAction(
        title: String,
        candidates: [Track],
        callback: ((Track) -> Void)?,
        allAction: (([Track]) -> Void)? = nil
    ) -> (() -> Void)? {
        guard let callback, let first = candidates.first else { return nil }
        guard candidates.count > 1, let onSelectMutationSource else {
            return { callback(first) }
        }
        return { onSelectMutationSource(title, candidates, allAction, callback) }
    }
}

extension TrackRowInteractionModel {
    @MainActor
    static func nowPlayingActions(
        nowPlayingVM: NowPlayingViewModel,
        deps: DependencyContainer,
        navigationCoordinator: NavigationCoordinator? = nil,
        includeAlbumNavigation: Bool = true,
        includeArtistNavigation: Bool = true,
        recentPlaylistTitle: String?,
        mutationCandidates: ((Track) -> [Track])? = nil,
        sourceActionPresenter: MediaSourceActionPresenter? = nil,
        onAddToPlaylist: @escaping ([Track]) -> Void,
        onGetInfo: @escaping (Track) -> Void
    ) -> TrackRowInteractionModel {
        let goToAlbum: ((Track) -> Void)?
        if includeAlbumNavigation, let navigationCoordinator {
            goToAlbum = { track in
                guard let albumId = track.albumRatingKey else { return }
                navigationCoordinator.routeFromMenu(
                    to: .album(id: albumId, sourceKey: track.sourceCompositeKey),
                    in: navigationCoordinator.selectedTab
                )
            }
        } else {
            goToAlbum = nil
        }
        let goToArtist: ((Track) -> Void)?
        if includeArtistNavigation, let navigationCoordinator {
            goToArtist = { track in
                guard let artistId = track.artistRatingKey else { return }
                navigationCoordinator.routeFromMenu(
                    to: .artist(id: artistId, sourceKey: track.sourceCompositeKey),
                    in: navigationCoordinator.selectedTab
                )
            }
        } else {
            goToArtist = nil
        }

        return TrackRowInteractionModel(
            onPlayNext: { track in
                nowPlayingVM.playNext(track)
            },
            onPlayLast: { track in
                nowPlayingVM.playLast(track)
            },
            onAddToLibrary: { track in
                Task { await nowPlayingVM.addTrackToLibrary(track) }
            },
            onAddToPlaylist: { track in
                onAddToPlaylist([track])
            },
            onAddToRecentPlaylist: { track in
                PlaylistActionPresentationHost.addToRecentPlaylist([track], nowPlayingVM: nowPlayingVM)
            },
            onToggleFavorite: { track in
                Task {
                    await nowPlayingVM.toggleTrackFavorite(track)
                }
            },
            onGoToAlbum: goToAlbum,
            onGoToArtist: goToArtist,
            onGetInfo: onGetInfo,
            onShareEnsembleLink: { track in
                ShareActions.shareEnsembleLink(track, deps: deps)
            },
            onShareLink: { track in
                ShareActions.shareTrackLink(track, deps: deps)
            },
            onShareFile: { track in
                ShareActions.shareTrackFile(track, deps: deps)
            },
            onToggleHidden: { track in
                track.hiddenToggleAction(deps: deps)?()
            },
            isTrackFavorited: { track in
                nowPlayingVM.isTrackFavorited(track)
            },
            isTrackHidden: { track in
                track.hiddenIdentity(deps: deps) != nil
            },
            canToggleHidden: { track in
                track.hiddenIdentity(deps: deps) != nil || track.hiddenCandidate(deps: deps) != nil
            },
            canAddToLibrary: { track in
                nowPlayingVM.canAddTrackToLibrary(track)
            },
            canAddToRecentPlaylist: { track in
                PlaylistActionPresentationHost.recentPlaylistTitle(for: [track], nowPlayingVM: nowPlayingVM) != nil
            },
            recentPlaylistTitle: recentPlaylistTitle,
            recentPlaylistTitleForTrack: { track in
                PlaylistActionPresentationHost.recentPlaylistTitle(
                    for: [track],
                    nowPlayingVM: nowPlayingVM
                )
            },
            mutationCandidates: mutationCandidates,
            onSelectMutationSource: sourceActionPresenter.map { presenter in
                { title, tracks, allAction, action in
                    sourceMutationAction(
                        title: title,
                        tracks: tracks,
                        allAction: allAction,
                        presenter: presenter,
                        deps: deps,
                        action: action
                    )?()
                }
            }
        )
    }
}
