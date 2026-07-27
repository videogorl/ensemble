import EnsembleCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Shared swipe presentation for native table-backed media rows.
///
/// UIKit and AppKit expose different row-action types, but they should agree on
/// action availability, labels, symbols, colors, and confirmation toasts.
enum TrackActionPresentation {
    static func isSupported(
        _ action: TrackSwipeAction,
        resolvedActions: TrackRowInteractionModel.ResolvedActions
    ) -> Bool {
        switch action {
        case .playNext:
            return resolvedActions.onPlayNext != nil
        case .playLast:
            return resolvedActions.onPlayLast != nil
        case .addToPlaylist:
            return resolvedActions.onAddToPlaylist != nil
        case .favoriteToggle:
            return resolvedActions.onToggleFavorite != nil
        }
    }

    static func title(
        for action: TrackSwipeAction,
        resolvedActions: TrackRowInteractionModel.ResolvedActions
    ) -> String {
        switch action {
        case .favoriteToggle:
            return resolvedActions.isFavorited ? "Unfavorite" : "Favorite"
        default:
            return action.title
        }
    }

    static func systemImage(
        for action: TrackSwipeAction,
        resolvedActions: TrackRowInteractionModel.ResolvedActions
    ) -> String {
        switch action {
        case .favoriteToggle:
            return resolvedActions.isFavorited ? EnsembleDesign.Icon.favoriteRemoveFilled : EnsembleDesign.Icon.favoriteFilled
        default:
            return action.systemImage
        }
    }

    static func tint(
        for action: TrackSwipeAction,
        resolvedActions: TrackRowInteractionModel.ResolvedActions
    ) -> Color {
        switch action {
        case .favoriteToggle:
            return resolvedActions.isFavorited ? EnsembleDesign.Color.neutralStatus : EnsembleDesign.Color.favorite
        default:
            return action.tint
        }
    }

    static func execute(
        _ action: TrackSwipeAction,
        resolvedActions: TrackRowInteractionModel.ResolvedActions
    ) {
        switch action {
        case .playNext:
            resolvedActions.onPlayNext?()
        case .playLast:
            resolvedActions.onPlayLast?()
        case .addToPlaylist:
            resolvedActions.onAddToPlaylist?()
        case .favoriteToggle:
            resolvedActions.onToggleFavorite?()
        }
    }

    static func confirmationToast(
        for action: TrackSwipeAction,
        track: Track,
        dedupeNamespace: String
    ) -> ToastPayload? {
        let trackIdentity = track.sourceScopedID
        switch action {
        case .playNext:
            return ToastPayload(
                style: .success,
                iconSystemName: EnsembleDesign.Icon.playNext,
                title: "Play Next",
                message: "Added \(track.title).",
                dedupeKey: "\(dedupeNamespace)-swipe-play-next-\(trackIdentity)"
            )
        case .playLast:
            return ToastPayload(
                style: .success,
                iconSystemName: EnsembleDesign.Icon.playLast,
                title: "Play Last",
                message: "Queued \(track.title) for later.",
                dedupeKey: "\(dedupeNamespace)-swipe-play-last-\(trackIdentity)"
            )
        case .addToPlaylist:
            return ToastPayload(
                style: .info,
                iconSystemName: EnsembleDesign.Icon.addToPlaylist,
                title: "Add to Playlist…",
                message: "Choose a playlist to continue.",
                dedupeKey: "\(dedupeNamespace)-swipe-add-to-playlist-\(trackIdentity)"
            )
        case .favoriteToggle:
            return nil
        }
    }

    static func favoriteLoadingToast(
        for track: Track,
        willFavorite: Bool,
        dedupeNamespace: String
    ) -> ToastPayload {
        ToastPayload(
            style: .info,
            iconSystemName: willFavorite ? EnsembleDesign.Icon.favoriteFilled : EnsembleDesign.Icon.favoriteRemoveFilled,
            title: willFavorite ? "Adding to Favorites..." : "Removing from Favorites...",
            message: track.title,
            duration: 1.0,
            dedupeKey: "\(dedupeNamespace)-favorite-toggle-loading-\(track.sourceScopedID)",
            showsActivityIndicator: true
        )
    }
}

private func nativeMediaTableMenuAvailability(
    for track: Track,
    resolvedActions: TrackRowInteractionModel.ResolvedActions,
    onRemoveFromPlaylist: (() -> Void)?,
    onRemoveFromQueue: (() -> Void)?
) -> MediaMenuAvailability {
    MediaMenuAvailability(
        hasRecentPlaylist: resolvedActions.onAddToRecentPlaylist != nil && resolvedActions.recentPlaylistTitle != nil,
        canAddToLibrary: resolvedActions.onAddToLibrary != nil,
        canAddToRecentPlaylist: true,
        canGoToAlbum: resolvedActions.onGoToAlbum != nil && track.albumRatingKey != nil,
        canGoToArtist: resolvedActions.onGoToArtist != nil && track.artistRatingKey != nil,
        canGetInfo: resolvedActions.onGetInfo != nil,
        canShareEnsembleLink: resolvedActions.onShareEnsembleLink != nil,
        canShareLink: resolvedActions.onShareLink != nil,
        canShareAudioFile: resolvedActions.onShareFile != nil,
        canFavorite: resolvedActions.onToggleFavorite != nil,
        canDownload: false,
        canPin: false,
        canEditMetadata: resolvedActions.onEditMetadata != nil,
        canDelete: resolvedActions.onDeleteTrack != nil,
        canRename: false,
        canEditPlaylist: false,
        canRemoveFromPlaylist: onRemoveFromPlaylist != nil,
        canRemoveFromQueue: onRemoveFromQueue != nil
    )
}

private func nativeMediaTableMenuHandlers(
    for resolvedActions: TrackRowInteractionModel.ResolvedActions,
    onRemoveFromPlaylist: (() -> Void)?,
    onRemoveFromQueue: (() -> Void)?
) -> MediaMenuHandlers {
    MediaMenuHandlers(
        playNext: resolvedActions.onPlayNext,
        playLast: resolvedActions.onPlayLast,
        addToLibrary: resolvedActions.onAddToLibrary,
        addToRecentPlaylist: resolvedActions.onAddToRecentPlaylist,
        addToPlaylist: resolvedActions.onAddToPlaylist,
        goToAlbum: resolvedActions.onGoToAlbum,
        goToArtist: resolvedActions.onGoToArtist,
        getInfo: resolvedActions.onGetInfo,
        editMetadata: resolvedActions.onEditMetadata,
        favorite: resolvedActions.onToggleFavorite,
        shareEnsembleLink: resolvedActions.onShareEnsembleLink,
        shareLink: resolvedActions.onShareLink,
        shareAudioFile: resolvedActions.onShareFile,
        removeFromPlaylist: onRemoveFromPlaylist,
        removeFromQueue: onRemoveFromQueue,
        deleteTrack: resolvedActions.onDeleteTrack
    )
}

#if canImport(UIKit)

/// Builds native UIKit menu actions for table-backed media rows.
///
/// This intentionally covers menus only. Swipe gestures stay owned by
/// `MediaTrackList` so card and shelf interfaces do not inherit row gestures.
enum NativeMediaTableActionBuilder {
    static func contextMenu(
        for track: Track,
        resolvedActions: TrackRowInteractionModel.ResolvedActions,
        context: MediaMenuContext = .library,
        onRemoveFromPlaylist: (() -> Void)? = nil,
        onRemoveFromQueue: (() -> Void)? = nil
    ) -> UIMenu? {
        guard resolvedActions.hasContextMenu || onRemoveFromPlaylist != nil || onRemoveFromQueue != nil else { return nil }

        return UIKitMediaMenuRenderer.contextMenu(
            sections: MediaMenuCatalog.sections(
                for: .track,
                context: context,
                availability: nativeMediaTableMenuAvailability(
                    for: track,
                    resolvedActions: resolvedActions,
                    onRemoveFromPlaylist: onRemoveFromPlaylist,
                    onRemoveFromQueue: onRemoveFromQueue
                )
            ),
            state: MediaMenuState(
                recentPlaylistTitle: resolvedActions.recentPlaylistTitle,
                isFavorited: resolvedActions.isFavorited
            ),
            handlers: nativeMediaTableMenuHandlers(
                for: resolvedActions,
                onRemoveFromPlaylist: onRemoveFromPlaylist,
                onRemoveFromQueue: onRemoveFromQueue
            )
        )
    }
}
#endif

#if canImport(AppKit)
/// Builds native AppKit menu actions for table-backed media rows.
enum NativeMediaTableActionBuilder {
    static func contextMenu(
        for track: Track,
        resolvedActions: TrackRowInteractionModel.ResolvedActions,
        context: MediaMenuContext = .library,
        onRemoveFromPlaylist: (() -> Void)? = nil,
        onRemoveFromQueue: (() -> Void)? = nil
    ) -> NSMenu? {
        guard resolvedActions.hasContextMenu || onRemoveFromPlaylist != nil || onRemoveFromQueue != nil else { return nil }

        return AppKitMediaMenuRenderer.contextMenu(
            sections: MediaMenuCatalog.sections(
                for: .track,
                context: context,
                availability: nativeMediaTableMenuAvailability(
                    for: track,
                    resolvedActions: resolvedActions,
                    onRemoveFromPlaylist: onRemoveFromPlaylist,
                    onRemoveFromQueue: onRemoveFromQueue
                )
            ),
            state: MediaMenuState(
                recentPlaylistTitle: resolvedActions.recentPlaylistTitle,
                isFavorited: resolvedActions.isFavorited
            ),
            handlers: nativeMediaTableMenuHandlers(
                for: resolvedActions,
                onRemoveFromPlaylist: onRemoveFromPlaylist,
                onRemoveFromQueue: onRemoveFromQueue
            )
        )
    }
}
#endif
