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
        public let isFavorited: Bool
        public let recentPlaylistTitle: String?

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
            onDeleteTrack != nil
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
    public let isTrackFavorited: ((Track) -> Bool)?
    public let canAddToRecentPlaylist: ((Track) -> Bool)?
    public let recentPlaylistTitle: String?

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
        isTrackFavorited: ((Track) -> Bool)? = nil,
        canAddToRecentPlaylist: ((Track) -> Bool)? = nil,
        recentPlaylistTitle: String? = nil
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
        self.isTrackFavorited = isTrackFavorited
        self.canAddToRecentPlaylist = canAddToRecentPlaylist
        self.recentPlaylistTitle = recentPlaylistTitle
    }

    public func isFavorited(_ track: Track) -> Bool {
        isTrackFavorited?(track) ?? track.isFavorite
    }

    public func hasContextMenu(for track: Track) -> Bool {
        guard track.isLibraryAvailable else { return false }
        let allowRecentPlaylist = onAddToRecentPlaylist != nil && (canAddToRecentPlaylist?(track) ?? true)

        return onPlayNext != nil ||
            onPlayLast != nil ||
            (track.canAddToSourceLibrary && onAddToLibrary != nil) ||
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
            onDeleteTrack != nil
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
                isFavorited: false,
                recentPlaylistTitle: nil
            )
        }
        let allowRecentPlaylist = onAddToRecentPlaylist != nil && (canAddToRecentPlaylist?(track) ?? true)
        let canToggleFavorite = track.sourceCapabilities.supportsFavoriteRemoval || !isFavorited(track)

        return ResolvedActions(
            onPlayNext: onPlayNext.map { callback in { callback(track) } },
            onPlayLast: onPlayLast.map { callback in { callback(track) } },
            onAddToLibrary: track.canAddToSourceLibrary ? onAddToLibrary.map { callback in { callback(track) } } : nil,
            onAddToPlaylist: onAddToPlaylist.map { callback in { callback(track) } },
            onAddToRecentPlaylist: allowRecentPlaylist ? onAddToRecentPlaylist.map { callback in { callback(track) } } : nil,
            onToggleFavorite: canToggleFavorite ? onToggleFavorite.map { callback in { callback(track) } } : nil,
            onGoToAlbum: onGoToAlbum.map { callback in { callback(track) } },
            onGoToArtist: onGoToArtist.map { callback in { callback(track) } },
            onGetInfo: onGetInfo.map { callback in { callback(track) } },
            onEditMetadata: track.sourceCapabilities.supportsMetadataEditing ? onEditMetadata.map { callback in { callback(track) } } : nil,
            onShareEnsembleLink: onShareEnsembleLink.map { callback in { callback(track) } },
            onShareLink: onShareLink.map { callback in { callback(track) } },
            onShareFile: track.sourceCapabilities.supportsAudioFileSharing ? onShareFile.map { callback in { callback(track) } } : nil,
            onDeleteTrack: track.sourceCapabilities.supportsTrackDeletion ? onDeleteTrack.map { callback in { callback(track) } } : nil,
            isFavorited: isFavorited(track),
            recentPlaylistTitle: allowRecentPlaylist ? recentPlaylistTitle : nil
        )
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
            isTrackFavorited: { track in
                nowPlayingVM.isTrackFavorited(track)
            },
            canAddToRecentPlaylist: { track in
                PlaylistActionPresentationHost.recentPlaylistTitle(for: [track], nowPlayingVM: nowPlayingVM) != nil
            },
            recentPlaylistTitle: recentPlaylistTitle
        )
    }
}
