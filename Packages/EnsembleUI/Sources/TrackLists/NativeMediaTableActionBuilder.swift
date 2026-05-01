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
enum NativeTrackSwipeActionPresenter {
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
        track: Track,
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
        switch action {
        case .playNext:
            return ToastPayload(
                style: .success,
                iconSystemName: EnsembleDesign.Icon.playNext,
                title: "Play Next",
                message: "Added \(track.title).",
                dedupeKey: "\(dedupeNamespace)-swipe-play-next-\(track.id)"
            )
        case .playLast:
            return ToastPayload(
                style: .success,
                iconSystemName: EnsembleDesign.Icon.playLast,
                title: "Play Last",
                message: "Queued \(track.title) for later.",
                dedupeKey: "\(dedupeNamespace)-swipe-play-last-\(track.id)"
            )
        case .addToPlaylist:
            return ToastPayload(
                style: .info,
                iconSystemName: EnsembleDesign.Icon.addToPlaylist,
                title: "Add to Playlist…",
                message: "Choose a playlist to continue.",
                dedupeKey: "\(dedupeNamespace)-swipe-add-to-playlist-\(track.id)"
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
            dedupeKey: "\(dedupeNamespace)-favorite-toggle-loading-\(track.id)",
            showsActivityIndicator: true
        )
    }
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

#if canImport(AppKit)
/// Builds native AppKit menu actions for table-backed media rows.
enum NativeMediaTableActionBuilder {
    static func contextMenu(
        for track: Track,
        resolvedActions: TrackRowInteractionModel.ResolvedActions,
        extraBottomActions: [NSMenuItem] = []
    ) -> NSMenu? {
        guard resolvedActions.hasContextMenu || !extraBottomActions.isEmpty else { return nil }

        let menu = NSMenu()

        addSection(to: menu, actions: [
            resolvedActions.onPlayNext.map {
                item("Play Next", systemImage: EnsembleDesign.Icon.playNext, action: $0)
            },
            resolvedActions.onPlayLast.map {
                item("Play Last", systemImage: EnsembleDesign.Icon.playLast, action: $0)
            }
        ])

        addSection(to: menu, actions: [
            (resolvedActions.onGoToAlbum != nil && track.albumRatingKey != nil)
                ? item("Go to Album", systemImage: EnsembleDesign.Icon.album, action: resolvedActions.onGoToAlbum!)
                : nil,
            (resolvedActions.onGoToArtist != nil && track.artistRatingKey != nil)
                ? item("Go to Artist", systemImage: EnsembleDesign.Icon.artist, action: resolvedActions.onGoToArtist!)
                : nil
        ])

        var bottomActions: [NSMenuItem?] = []
        if let onAddToRecentPlaylist = resolvedActions.onAddToRecentPlaylist,
           let recentPlaylistTitle = resolvedActions.recentPlaylistTitle {
            bottomActions.append(item(
                "Add to \(recentPlaylistTitle)",
                systemImage: EnsembleDesign.Icon.recentPlaylist,
                action: onAddToRecentPlaylist
            ))
        }
        if let onAddToPlaylist = resolvedActions.onAddToPlaylist {
            bottomActions.append(item("Add to Playlist…", systemImage: EnsembleDesign.Icon.addToPlaylist, action: onAddToPlaylist))
        }
        if let onToggleFavorite = resolvedActions.onToggleFavorite {
            bottomActions.append(item(
                resolvedActions.isFavorited ? "Unfavorite" : "Favorite",
                systemImage: resolvedActions.isFavorited ? EnsembleDesign.Icon.favoriteRemove : EnsembleDesign.Icon.favorite,
                action: onToggleFavorite
            ))
        }
        bottomActions.append(contentsOf: extraBottomActions)
        addSection(to: menu, actions: bottomActions)

        addSection(to: menu, actions: [
            resolvedActions.onShareLink.map {
                item("Share Link…", systemImage: EnsembleDesign.Icon.shareLink, action: $0)
            },
            resolvedActions.onShareFile.map {
                item("Share Audio File…", systemImage: EnsembleDesign.Icon.shareAudioFile, action: $0)
            }
        ])

        return menu.items.isEmpty ? nil : menu
    }

    private static func addSection(to menu: NSMenu, actions: [NSMenuItem?]) {
        let concreteActions = actions.compactMap { $0 }
        guard !concreteActions.isEmpty else { return }

        addSeparatorIfNeeded(to: menu)
        concreteActions.forEach(menu.addItem)
    }

    private static func item(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let menuItem = NativeClosureMenuItem(title: title, action: action)
        menuItem.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
        return menuItem
    }

    private static func addSeparatorIfNeeded(to menu: NSMenu) {
        guard let last = menu.items.last, !last.isSeparatorItem else { return }
        menu.addItem(.separator())
    }
}

private final class NativeClosureMenuItem: NSMenuItem {
    private let closure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.closure = action
        super.init(title: title, action: #selector(runClosure), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        self.closure = {}
        super.init(coder: coder)
        target = self
        action = #selector(runClosure)
    }

    @objc private func runClosure() {
        closure()
    }
}
#endif
