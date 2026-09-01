import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

/// Shared labels for media actions so menus, swipe actions, and toolbar-adjacent controls
/// use the same wording and SF Symbols.
struct MediaActionLabel: View {
    enum Kind {
        case play
        case shuffle
        case toggleShuffle(isEnabled: Bool)
        case repeatAll(isEnabled: Bool)
        case repeatOne(isEnabled: Bool)
        case radio
        case playNext
        case playLast
        case addToLibrary
        case addToPlaylist
        case addToRecentPlaylist(String)
        case goToAlbum
        case goToArtist
        case getInfo
        case editMetadata
        case rename
        case editPlaylist
        case download(isDownloaded: Bool)
        case favorite(isFavorited: Bool, usesFilledIcon: Bool)
        case pin(isPinned: Bool)
        case unpinAll
        case toggleHidden(isHidden: Bool)
        case shareEnsembleLink
        case shareLink
        case shareAudioFile
        case removeFromPlaylist
        case removeFromQueue
        case deleteTrack
        case deleteAlbum
        case deletePlaylist
    }

    let kind: Kind

    var body: some View {
        Label(title, systemImage: systemImage)
    }

    private var title: String {
        switch kind {
        case .play:
            return "Play"
        case .shuffle:
            return "Shuffle"
        case .toggleShuffle(let isEnabled):
            return isEnabled ? "Turn Shuffle Off" : "Turn Shuffle On"
        case .repeatAll(let isEnabled):
            return isEnabled ? "Repeat On" : "Repeat"
        case .repeatOne(let isEnabled):
            return isEnabled ? "Repeat One On" : "Repeat One"
        case .radio:
            return "Radio"
        case .playNext:
            return "Play Next"
        case .playLast:
            return "Play Last"
        case .addToLibrary:
            return "Add to Library"
        case .addToPlaylist:
            return "Add to Playlist…"
        case .addToRecentPlaylist(let playlistTitle):
            return "Add to \(playlistTitle)"
        case .goToAlbum:
            return "Go to Album"
        case .goToArtist:
            return "Go to Artist"
        case .getInfo:
            return "Get Info…"
        case .editMetadata:
            return "Edit Metadata…"
        case .rename:
            return "Rename…"
        case .editPlaylist:
            return "Edit Playlist"
        case .download(let isDownloaded):
            return isDownloaded ? "Remove Download" : "Download"
        case .favorite(let isFavorited, _):
            return isFavorited ? "Unfavorite" : "Favorite"
        case .pin(let isPinned):
            return isPinned ? "Unpin" : "Pin"
        case .unpinAll:
            return "Unpin All"
        case .toggleHidden(let isHidden):
            return isHidden ? "Unhide" : "Hide"
        case .shareEnsembleLink:
            return "Share Ensemble Link…"
        case .shareLink:
            return "Share Link…"
        case .shareAudioFile:
            return "Share Audio File…"
        case .removeFromPlaylist:
            return "Remove from Playlist"
        case .removeFromQueue:
            return "Remove from Queue"
        case .deleteTrack:
            return "Delete Track"
        case .deleteAlbum:
            return "Delete Album"
        case .deletePlaylist:
            return "Delete Playlist"
        }
    }

    private var systemImage: String {
        switch kind {
        case .play:
            return EnsembleDesign.Icon.play
        case .shuffle, .toggleShuffle:
            return EnsembleDesign.Icon.shuffle
        case .repeatAll:
            return RepeatMode.all.icon
        case .repeatOne:
            return RepeatMode.one.icon
        case .radio:
            return EnsembleDesign.Icon.radio
        case .playNext:
            return EnsembleDesign.Icon.playNext
        case .playLast:
            return EnsembleDesign.Icon.playLast
        case .addToLibrary:
            return "text.badge.plus"
        case .addToPlaylist:
            return EnsembleDesign.Icon.addToPlaylist
        case .addToRecentPlaylist:
            return EnsembleDesign.Icon.recentPlaylist
        case .goToAlbum:
            return EnsembleDesign.Icon.album
        case .goToArtist:
            return EnsembleDesign.Icon.artist
        case .getInfo:
            return EnsembleDesign.Icon.info
        case .editMetadata, .rename:
            return EnsembleDesign.Icon.edit
        case .editPlaylist:
            return EnsembleDesign.Icon.editPlaylist
        case .download(let isDownloaded):
            return isDownloaded ? EnsembleDesign.Icon.removeDownload : EnsembleDesign.Icon.download
        case .favorite(let isFavorited, let usesFilledIcon):
            if usesFilledIcon {
                return isFavorited ? EnsembleDesign.Icon.favoriteRemoveFilled : EnsembleDesign.Icon.favoriteFilled
            }
            return isFavorited ? EnsembleDesign.Icon.favoriteRemove : EnsembleDesign.Icon.favorite
        case .pin(let isPinned):
            return isPinned ? EnsembleDesign.Icon.unpin : EnsembleDesign.Icon.pin
        case .unpinAll:
            return EnsembleDesign.Icon.unpin
        case .toggleHidden(let isHidden):
            return isHidden ? "eye" : "eye.slash"
        case .shareEnsembleLink, .shareLink:
            return EnsembleDesign.Icon.shareLink
        case .shareAudioFile:
            return EnsembleDesign.Icon.shareAudioFile
        case .removeFromPlaylist:
            return EnsembleDesign.Icon.removeFromPlaylist
        case .removeFromQueue:
            return EnsembleDesign.Icon.removeCircle
        case .deleteTrack, .deleteAlbum, .deletePlaylist:
            return EnsembleDesign.Icon.delete
        }
    }
}
