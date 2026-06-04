import EnsembleCore

/// Resolves per-track row actions so SwiftUI and UIKit lists share the same
/// menu availability, favorite state, and recent-playlist gating logic.
public struct TrackRowInteractionModel {
    public struct ResolvedActions {
        public let onPlayNext: (() -> Void)?
        public let onPlayLast: (() -> Void)?
        public let onAddToPlaylist: (() -> Void)?
        public let onAddToRecentPlaylist: (() -> Void)?
        public let onToggleFavorite: (() -> Void)?
        public let onGoToAlbum: (() -> Void)?
        public let onGoToArtist: (() -> Void)?
        public let onGetInfo: (() -> Void)?
        public let onEditMetadata: (() -> Void)?
        public let onShareLink: (() -> Void)?
        public let onShareFile: (() -> Void)?
        public let onDeleteTrack: (() -> Void)?
        public let isFavorited: Bool
        public let recentPlaylistTitle: String?

        public var hasContextMenu: Bool {
            onPlayNext != nil ||
            onPlayLast != nil ||
            onAddToPlaylist != nil ||
            onAddToRecentPlaylist != nil ||
            onToggleFavorite != nil ||
            onGoToAlbum != nil ||
            onGoToArtist != nil ||
            onGetInfo != nil ||
            onEditMetadata != nil ||
            onShareLink != nil ||
            onShareFile != nil ||
            onDeleteTrack != nil
        }
    }

    public let onPlayNext: ((Track) -> Void)?
    public let onPlayLast: ((Track) -> Void)?
    public let onAddToPlaylist: ((Track) -> Void)?
    public let onAddToRecentPlaylist: ((Track) -> Void)?
    public let onToggleFavorite: ((Track) -> Void)?
    public let onGoToAlbum: ((Track) -> Void)?
    public let onGoToArtist: ((Track) -> Void)?
    public let onGetInfo: ((Track) -> Void)?
    public let onEditMetadata: ((Track) -> Void)?
    public let onShareLink: ((Track) -> Void)?
    public let onShareFile: ((Track) -> Void)?
    public let onDeleteTrack: ((Track) -> Void)?
    public let isTrackFavorited: ((Track) -> Bool)?
    public let canAddToRecentPlaylist: ((Track) -> Bool)?
    public let recentPlaylistTitle: String?

    public init(
        onPlayNext: ((Track) -> Void)? = nil,
        onPlayLast: ((Track) -> Void)? = nil,
        onAddToPlaylist: ((Track) -> Void)? = nil,
        onAddToRecentPlaylist: ((Track) -> Void)? = nil,
        onToggleFavorite: ((Track) -> Void)? = nil,
        onGoToAlbum: ((Track) -> Void)? = nil,
        onGoToArtist: ((Track) -> Void)? = nil,
        onGetInfo: ((Track) -> Void)? = nil,
        onEditMetadata: ((Track) -> Void)? = nil,
        onShareLink: ((Track) -> Void)? = nil,
        onShareFile: ((Track) -> Void)? = nil,
        onDeleteTrack: ((Track) -> Void)? = nil,
        isTrackFavorited: ((Track) -> Bool)? = nil,
        canAddToRecentPlaylist: ((Track) -> Bool)? = nil,
        recentPlaylistTitle: String? = nil
    ) {
        self.onPlayNext = onPlayNext
        self.onPlayLast = onPlayLast
        self.onAddToPlaylist = onAddToPlaylist
        self.onAddToRecentPlaylist = onAddToRecentPlaylist
        self.onToggleFavorite = onToggleFavorite
        self.onGoToAlbum = onGoToAlbum
        self.onGoToArtist = onGoToArtist
        self.onGetInfo = onGetInfo
        self.onEditMetadata = onEditMetadata
        self.onShareLink = onShareLink
        self.onShareFile = onShareFile
        self.onDeleteTrack = onDeleteTrack
        self.isTrackFavorited = isTrackFavorited
        self.canAddToRecentPlaylist = canAddToRecentPlaylist
        self.recentPlaylistTitle = recentPlaylistTitle
    }

    public func resolve(for track: Track) -> ResolvedActions {
        let allowRecentPlaylist = onAddToRecentPlaylist != nil && (canAddToRecentPlaylist?(track) ?? true)

        return ResolvedActions(
            onPlayNext: onPlayNext.map { callback in { callback(track) } },
            onPlayLast: onPlayLast.map { callback in { callback(track) } },
            onAddToPlaylist: onAddToPlaylist.map { callback in { callback(track) } },
            onAddToRecentPlaylist: allowRecentPlaylist ? onAddToRecentPlaylist.map { callback in { callback(track) } } : nil,
            onToggleFavorite: onToggleFavorite.map { callback in { callback(track) } },
            onGoToAlbum: onGoToAlbum.map { callback in { callback(track) } },
            onGoToArtist: onGoToArtist.map { callback in { callback(track) } },
            onGetInfo: onGetInfo.map { callback in { callback(track) } },
            onEditMetadata: onEditMetadata.map { callback in { callback(track) } },
            onShareLink: onShareLink.map { callback in { callback(track) } },
            onShareFile: onShareFile.map { callback in { callback(track) } },
            onDeleteTrack: onDeleteTrack.map { callback in { callback(track) } },
            isFavorited: isTrackFavorited?(track) ?? (track.rating >= 8),
            recentPlaylistTitle: allowRecentPlaylist ? recentPlaylistTitle : nil
        )
    }
}
