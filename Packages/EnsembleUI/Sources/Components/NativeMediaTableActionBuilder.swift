import EnsembleCore

#if canImport(UIKit)
import UIKit

/// Builds native UIKit menu actions for table-backed media rows.
///
/// This intentionally covers menus only. Swipe gestures stay owned by
/// `MediaTrackList` so card and shelf interfaces do not inherit row gestures.
enum NativeMediaTableActionBuilder {
    static func contextMenu(
        for track: Track,
        resolvedActions: TrackRowInteractionModel.ResolvedActions,
        extraBottomActions: [UIAction] = []
    ) -> UIMenu? {
        guard resolvedActions.hasContextMenu || !extraBottomActions.isEmpty else { return nil }

        var topActions: [UIAction] = []
        if let onPlayNext = resolvedActions.onPlayNext {
            topActions.append(UIAction(title: "Play Next", image: UIImage(systemName: EnsembleDesign.Icon.playNext)) { _ in
                onPlayNext()
            })
        }
        if let onPlayLast = resolvedActions.onPlayLast {
            topActions.append(UIAction(title: "Play Last", image: UIImage(systemName: EnsembleDesign.Icon.playLast)) { _ in
                onPlayLast()
            })
        }

        var navigationActions: [UIAction] = []
        if let onGoToAlbum = resolvedActions.onGoToAlbum, track.albumRatingKey != nil {
            navigationActions.append(UIAction(title: "Go to Album", image: UIImage(systemName: EnsembleDesign.Icon.album)) { _ in
                onGoToAlbum()
            })
        }
        if let onGoToArtist = resolvedActions.onGoToArtist, track.artistRatingKey != nil {
            navigationActions.append(UIAction(title: "Go to Artist", image: UIImage(systemName: EnsembleDesign.Icon.artist)) { _ in
                onGoToArtist()
            })
        }

        var bottomActions: [UIAction] = []
        if let onAddToRecentPlaylist = resolvedActions.onAddToRecentPlaylist,
           let recentPlaylistTitle = resolvedActions.recentPlaylistTitle {
            bottomActions.append(UIAction(title: "Add to \(recentPlaylistTitle)", image: UIImage(systemName: EnsembleDesign.Icon.recentPlaylist)) { _ in
                onAddToRecentPlaylist()
            })
        }
        if let onAddToPlaylist = resolvedActions.onAddToPlaylist {
            bottomActions.append(UIAction(title: "Add to Playlist…", image: UIImage(systemName: EnsembleDesign.Icon.addToPlaylist)) { _ in
                onAddToPlaylist()
            })
        }
        if let onToggleFavorite = resolvedActions.onToggleFavorite {
            bottomActions.append(
                UIAction(
                    title: resolvedActions.isFavorited ? "Unfavorite" : "Favorite",
                    image: UIImage(systemName: resolvedActions.isFavorited ? EnsembleDesign.Icon.favoriteRemove : EnsembleDesign.Icon.favorite)
                ) { _ in
                    onToggleFavorite()
                }
            )
        }
        bottomActions.append(contentsOf: extraBottomActions)

        var shareActions: [UIAction] = []
        if let onShareLink = resolvedActions.onShareLink {
            shareActions.append(UIAction(title: "Share Link…", image: UIImage(systemName: EnsembleDesign.Icon.shareLink)) { _ in
                onShareLink()
            })
        }
        if let onShareFile = resolvedActions.onShareFile {
            shareActions.append(UIAction(title: "Share Audio File…", image: UIImage(systemName: EnsembleDesign.Icon.shareAudioFile)) { _ in
                onShareFile()
            })
        }

        var children: [UIMenuElement] = []
        appendInlineMenu(with: topActions, to: &children)
        appendInlineMenu(with: navigationActions, to: &children)
        appendInlineMenu(with: bottomActions, to: &children)
        appendInlineMenu(with: shareActions, to: &children)

        return children.isEmpty ? nil : UIMenu(children: children)
    }

    private static func appendInlineMenu(with actions: [UIAction], to children: inout [UIMenuElement]) {
        guard !actions.isEmpty else { return }
        children.append(UIMenu(title: "", options: .displayInline, children: actions))
    }
}
#endif
