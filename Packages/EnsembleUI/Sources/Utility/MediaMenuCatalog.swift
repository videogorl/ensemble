import EnsembleCore
import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Describes where a media menu is being presented so shared actions can stay
/// consistent while parent views add only their local extensions.
enum MediaMenuContext: Equatable {
    case library
    case detail
    case search
    case pinned
    case sidebar
    case miniPlayer
    case nowPlayingControls
    case queue(canRemove: Bool)
    case history
    case stageFlow

    var allowsTrackEditing: Bool {
        switch self {
        case .library, .detail:
            return true
        case .search, .pinned, .sidebar, .miniPlayer, .nowPlayingControls, .queue, .history, .stageFlow:
            return false
        }
    }

    var allowsPlaylistManagement: Bool {
        switch self {
        case .library, .detail, .pinned, .sidebar:
            return true
        case .search, .miniPlayer, .nowPlayingControls, .queue, .history, .stageFlow:
            return false
        }
    }
}

/// The supported media item families for shared menu policy.
enum MediaMenuItemKind: Equatable {
    case track
    case album
    case artist
    case playlist(isSmart: Bool)
    case mergedPlaylist(isSmart: Bool)
}

/// Stable action identifiers used by SwiftUI, UIKit, and AppKit renderers.
enum MediaMenuActionID: String, Equatable, Hashable {
    case play
    case shuffle
    case toggleShuffle
    case repeatAll
    case repeatOne
    case radio
    case playNext
    case playLast
    case addToRecentPlaylist
    case addToPlaylist
    case goToAlbum
    case goToArtist
    case editMetadata
    case rename
    case renameAll
    case editPlaylist
    case download
    case downloadAll
    case removeDownloads
    case favorite
    case pin
    case unpinAll
    case shareLink
    case shareAudioFile
    case removeFromQueue
    case deleteTrack
    case deleteAlbum
    case deletePlaylist
    case deleteAll
}

enum MediaMenuSectionID: String, Equatable, Hashable {
    case playback
    case transport
    case playlist
    case navigation
    case sharing
    case offline
    case pinning
    case management
    case destructive
}

struct MediaMenuActionDescriptor: Equatable {
    enum Role: Equatable {
        case normal
        case destructive
    }

    let id: MediaMenuActionID
    let role: Role

    init(_ id: MediaMenuActionID, role: Role = .normal) {
        self.id = id
        self.role = role
    }
}

struct MediaMenuSection: Equatable {
    let id: MediaMenuSectionID
    let actions: [MediaMenuActionDescriptor]
}

struct MediaMenuLabel: Equatable {
    let title: String
    let systemImage: String
}

struct MediaMenuHandlers {
    var play: (() -> Void)?
    var shuffle: (() -> Void)?
    var toggleShuffle: (() -> Void)?
    var repeatAll: (() -> Void)?
    var repeatOne: (() -> Void)?
    var radio: (() -> Void)?
    var playNext: (() -> Void)?
    var playLast: (() -> Void)?
    var addToRecentPlaylist: (() -> Void)?
    var addToPlaylist: (() -> Void)?
    var goToAlbum: (() -> Void)?
    var goToArtist: (() -> Void)?
    var editMetadata: (() -> Void)?
    var rename: (() -> Void)?
    var renameAll: (() -> Void)?
    var editPlaylist: (() -> Void)?
    var download: (() -> Void)?
    var downloadAll: (() -> Void)?
    var removeDownloads: (() -> Void)?
    var favorite: (() -> Void)?
    var pin: (() -> Void)?
    var unpinAll: (() -> Void)?
    var shareLink: (() -> Void)?
    var shareAudioFile: (() -> Void)?
    var removeFromQueue: (() -> Void)?
    var deleteTrack: (() -> Void)?
    var deleteAlbum: (() -> Void)?
    var deletePlaylist: (() -> Void)?
    var deleteAll: (() -> Void)?

    func handler(for actionID: MediaMenuActionID) -> (() -> Void)? {
        switch actionID {
        case .play: return play
        case .shuffle: return shuffle
        case .toggleShuffle: return toggleShuffle
        case .repeatAll: return repeatAll
        case .repeatOne: return repeatOne
        case .radio: return radio
        case .playNext: return playNext
        case .playLast: return playLast
        case .addToRecentPlaylist: return addToRecentPlaylist
        case .addToPlaylist: return addToPlaylist
        case .goToAlbum: return goToAlbum
        case .goToArtist: return goToArtist
        case .editMetadata: return editMetadata
        case .rename: return rename
        case .renameAll: return renameAll
        case .editPlaylist: return editPlaylist
        case .download: return download
        case .downloadAll: return downloadAll
        case .removeDownloads: return removeDownloads
        case .favorite: return favorite
        case .pin: return pin
        case .unpinAll: return unpinAll
        case .shareLink: return shareLink
        case .shareAudioFile: return shareAudioFile
        case .removeFromQueue: return removeFromQueue
        case .deleteTrack: return deleteTrack
        case .deleteAlbum: return deleteAlbum
        case .deletePlaylist: return deletePlaylist
        case .deleteAll: return deleteAll
        }
    }
}

/// Dynamic menu state that affects action availability or labels without
/// changing the catalog's section policy.
struct MediaMenuAvailability: Equatable {
    var hasRecentPlaylist = false
    var canAddToRecentPlaylist = true
    var canGoToAlbum = false
    var canGoToArtist = false
    var canShareLink = true
    var canShareAudioFile = false
    var canFavorite = true
    var canDownload = true
    var canPin = true
    var canEditMetadata = true
    var canDelete = true
    var canRename = true
    var canEditPlaylist = true
    var canRemoveFromQueue = true

    static let full = MediaMenuAvailability(
        hasRecentPlaylist: true,
        canAddToRecentPlaylist: true,
        canGoToAlbum: true,
        canGoToArtist: true,
        canShareLink: true,
        canShareAudioFile: true,
        canFavorite: true,
        canDownload: true,
        canPin: true,
        canEditMetadata: true,
        canDelete: true,
        canRename: true,
        canEditPlaylist: true,
        canRemoveFromQueue: true
    )
}

/// Runtime values used by labels once an action is selected by the catalog.
struct MediaMenuState: Equatable {
    var recentPlaylistTitle: String?
    var isFavorited = false
    var isDownloaded = false
    var isPinned = false
    var isShuffleEnabled = false
    var repeatMode: RepeatMode = .off
}

/// Shared policy for media menu action order, grouping, and context gating.
enum MediaMenuCatalog {
    static func sections(
        for itemKind: MediaMenuItemKind,
        context: MediaMenuContext,
        availability: MediaMenuAvailability = .full
    ) -> [MediaMenuSection] {
        switch itemKind {
        case .track:
            return trackSections(context: context, availability: availability)
        case .album:
            return albumSections(context: context, availability: availability)
        case .artist:
            return artistSections(context: context, availability: availability)
        case .playlist(let isSmart):
            return playlistSections(isSmart: isSmart, context: context, availability: availability)
        case .mergedPlaylist(let isSmart):
            return mergedPlaylistSections(isSmart: isSmart, context: context, availability: availability)
        }
    }

    private static func trackSections(
        context: MediaMenuContext,
        availability: MediaMenuAvailability
    ) -> [MediaMenuSection] {
        var sections: [MediaMenuSection] = [
            section(.playback, [.playNext, .playLast])
        ]

        var playlistActions: [MediaMenuActionID] = []
        if availability.hasRecentPlaylist, availability.canAddToRecentPlaylist {
            playlistActions.append(.addToRecentPlaylist)
        }
        playlistActions.append(.addToPlaylist)
        if availability.canFavorite {
            playlistActions.append(.favorite)
        }
        sections.append(section(.playlist, playlistActions))

        var navigationActions: [MediaMenuActionID] = []
        if availability.canGoToAlbum {
            navigationActions.append(.goToAlbum)
        }
        if availability.canGoToArtist {
            navigationActions.append(.goToArtist)
        }
        sections.append(section(.navigation, navigationActions))

        var shareActions: [MediaMenuActionID] = []
        if availability.canShareLink {
            shareActions.append(.shareLink)
        }
        if availability.canShareAudioFile {
            shareActions.append(.shareAudioFile)
        }
        sections.append(section(.sharing, shareActions))

        if case .miniPlayer = context {
            sections.append(section(.transport, [.toggleShuffle, .repeatAll, .repeatOne]))
        }

        if case .queue(let canRemove) = context, canRemove, availability.canRemoveFromQueue {
            sections.append(section(.destructive, [.removeFromQueue], role: .destructive))
        }

        if context.allowsTrackEditing {
            var managementActions: [MediaMenuActionID] = []
            if availability.canEditMetadata {
                managementActions.append(.editMetadata)
            }
            if availability.canDelete {
                managementActions.append(.deleteTrack)
            }
            sections.append(section(.management, managementActions, destructive: [.deleteTrack]))
        }

        return sections.filter { !$0.actions.isEmpty }
    }

    private static func albumSections(
        context: MediaMenuContext,
        availability: MediaMenuAvailability
    ) -> [MediaMenuSection] {
        var sections = [
            section(.playback, [.play, .shuffle, .radio, .playNext, .playLast])
        ]

        var playlistActions: [MediaMenuActionID] = []
        if availability.hasRecentPlaylist, availability.canAddToRecentPlaylist {
            playlistActions.append(.addToRecentPlaylist)
        }
        playlistActions.append(.addToPlaylist)
        sections.append(section(.playlist, playlistActions))

        if availability.canGoToArtist {
            sections.append(section(.navigation, [.goToArtist]))
        }

        if availability.canShareLink {
            sections.append(section(.sharing, [.shareLink]))
        }

        var offlinePinning: [MediaMenuActionID] = []
        if availability.canDownload {
            offlinePinning.append(.download)
        }
        if availability.canPin {
            offlinePinning.append(.pin)
        }
        sections.append(section(.offline, offlinePinning))

        if context.allowsPlaylistManagement || context.allowsTrackEditing {
            var management: [MediaMenuActionID] = []
            if availability.canEditMetadata {
                management.append(.editMetadata)
            }
            if availability.canDelete {
                management.append(.deleteAlbum)
            }
            sections.append(section(.management, management, destructive: [.deleteAlbum]))
        }

        return sections.filter { !$0.actions.isEmpty }
    }

    private static func artistSections(
        context: MediaMenuContext,
        availability: MediaMenuAvailability
    ) -> [MediaMenuSection] {
        var sections = [
            section(.playback, [.play, .shuffle, .radio])
        ]

        var offlinePinning: [MediaMenuActionID] = []
        if availability.canDownload {
            offlinePinning.append(.download)
        }
        if availability.canPin {
            offlinePinning.append(.pin)
        }
        sections.append(section(.offline, offlinePinning))

        if context.allowsPlaylistManagement || context.allowsTrackEditing {
            var management: [MediaMenuActionID] = []
            if availability.canEditMetadata {
                management.append(.editMetadata)
            }
            sections.append(section(.management, management))
        }

        return sections.filter { !$0.actions.isEmpty }
    }

    private static func playlistSections(
        isSmart: Bool,
        context: MediaMenuContext,
        availability: MediaMenuAvailability
    ) -> [MediaMenuSection] {
        var sections = [
            section(.playback, [.play, .shuffle, .playNext, .playLast])
        ]

        var offlinePinning: [MediaMenuActionID] = []
        if availability.canDownload {
            offlinePinning.append(.download)
        }
        if availability.canPin {
            offlinePinning.append(.pin)
        }
        sections.append(section(.offline, offlinePinning))

        if context.allowsPlaylistManagement, !isSmart {
            var management: [MediaMenuActionID] = []
            if availability.canRename {
                management.append(.rename)
            }
            if availability.canEditPlaylist {
                management.append(.editPlaylist)
            }
            if availability.canDelete {
                management.append(.deletePlaylist)
            }
            sections.append(section(.management, management, destructive: [.deletePlaylist]))
        }

        return sections.filter { !$0.actions.isEmpty }
    }

    private static func mergedPlaylistSections(
        isSmart: Bool,
        context: MediaMenuContext,
        availability: MediaMenuAvailability
    ) -> [MediaMenuSection] {
        var sections = [
            section(.playback, [.play, .shuffle, .playNext, .playLast]),
            section(.offline, [.downloadAll, .removeDownloads])
        ]

        if context == .pinned || context == .sidebar {
            sections.append(section(.pinning, [.unpinAll], role: .destructive))
        }

        if context.allowsPlaylistManagement, !isSmart {
            var management: [MediaMenuActionID] = []
            if availability.canRename {
                management.append(.renameAll)
            }
            if availability.canDelete {
                management.append(.deleteAll)
            }
            sections.append(section(.management, management, destructive: [.deleteAll]))
        }

        return sections.filter { !$0.actions.isEmpty }
    }

    private static func section(
        _ id: MediaMenuSectionID,
        _ actions: [MediaMenuActionID],
        role: MediaMenuActionDescriptor.Role = .normal,
        destructive: Set<MediaMenuActionID> = []
    ) -> MediaMenuSection {
        MediaMenuSection(
            id: id,
            actions: actions.map { action in
                MediaMenuActionDescriptor(
                    action,
                    role: destructive.contains(action) ? .destructive : role
                )
            }
        )
    }
}

extension MediaMenuActionDescriptor {
    func label(state: MediaMenuState) -> MediaMenuLabel? {
        switch id {
        case .play:
            return MediaMenuLabel(title: "Play", systemImage: EnsembleDesign.Icon.play)
        case .shuffle:
            return MediaMenuLabel(title: "Shuffle", systemImage: EnsembleDesign.Icon.shuffle)
        case .toggleShuffle:
            return MediaMenuLabel(
                title: state.isShuffleEnabled ? "Turn Shuffle Off" : "Turn Shuffle On",
                systemImage: EnsembleDesign.Icon.shuffle
            )
        case .repeatAll:
            return MediaMenuLabel(
                title: state.repeatMode == .all ? "Repeat On" : "Repeat",
                systemImage: RepeatMode.all.icon
            )
        case .repeatOne:
            return MediaMenuLabel(
                title: state.repeatMode == .one ? "Repeat One On" : "Repeat One",
                systemImage: RepeatMode.one.icon
            )
        case .radio:
            return MediaMenuLabel(title: "Radio", systemImage: EnsembleDesign.Icon.radio)
        case .playNext:
            return MediaMenuLabel(title: "Play Next", systemImage: EnsembleDesign.Icon.playNext)
        case .playLast:
            return MediaMenuLabel(title: "Play Last", systemImage: EnsembleDesign.Icon.playLast)
        case .addToRecentPlaylist:
            guard let title = state.recentPlaylistTitle else { return nil }
            return MediaMenuLabel(title: "Add to \(title)", systemImage: EnsembleDesign.Icon.recentPlaylist)
        case .addToPlaylist:
            return MediaMenuLabel(title: "Add to Playlist…", systemImage: EnsembleDesign.Icon.addToPlaylist)
        case .goToAlbum:
            return MediaMenuLabel(title: "Go to Album", systemImage: EnsembleDesign.Icon.album)
        case .goToArtist:
            return MediaMenuLabel(title: "Go to Artist", systemImage: EnsembleDesign.Icon.artist)
        case .editMetadata:
            return MediaMenuLabel(title: "Edit Metadata…", systemImage: EnsembleDesign.Icon.edit)
        case .rename:
            return MediaMenuLabel(title: "Rename…", systemImage: EnsembleDesign.Icon.edit)
        case .renameAll:
            return MediaMenuLabel(title: "Rename All…", systemImage: EnsembleDesign.Icon.edit)
        case .editPlaylist:
            return MediaMenuLabel(title: "Edit Playlist", systemImage: EnsembleDesign.Icon.editPlaylist)
        case .download:
            return MediaMenuLabel(
                title: state.isDownloaded ? "Remove Download" : "Download",
                systemImage: state.isDownloaded ? EnsembleDesign.Icon.removeDownload : EnsembleDesign.Icon.download
            )
        case .downloadAll:
            return MediaMenuLabel(title: "Download All", systemImage: EnsembleDesign.Icon.download)
        case .removeDownloads:
            return MediaMenuLabel(title: "Remove Downloads", systemImage: EnsembleDesign.Icon.removeDownload)
        case .favorite:
            return MediaMenuLabel(
                title: state.isFavorited ? "Unfavorite" : "Favorite",
                systemImage: state.isFavorited ? EnsembleDesign.Icon.favoriteRemove : EnsembleDesign.Icon.favorite
            )
        case .pin:
            return MediaMenuLabel(
                title: state.isPinned ? "Unpin" : "Pin",
                systemImage: state.isPinned ? EnsembleDesign.Icon.unpin : EnsembleDesign.Icon.pin
            )
        case .unpinAll:
            return MediaMenuLabel(title: "Unpin All", systemImage: EnsembleDesign.Icon.unpin)
        case .shareLink:
            return MediaMenuLabel(title: "Share Link…", systemImage: EnsembleDesign.Icon.shareLink)
        case .shareAudioFile:
            return MediaMenuLabel(title: "Share Audio File…", systemImage: EnsembleDesign.Icon.shareAudioFile)
        case .removeFromQueue:
            return MediaMenuLabel(title: "Remove from Queue", systemImage: EnsembleDesign.Icon.removeCircle)
        case .deleteTrack:
            return MediaMenuLabel(title: "Delete Track", systemImage: EnsembleDesign.Icon.delete)
        case .deleteAlbum:
            return MediaMenuLabel(title: "Delete Album", systemImage: EnsembleDesign.Icon.delete)
        case .deletePlaylist:
            return MediaMenuLabel(title: "Delete Playlist", systemImage: EnsembleDesign.Icon.delete)
        case .deleteAll:
            return MediaMenuLabel(title: "Delete All", systemImage: EnsembleDesign.Icon.delete)
        }
    }

    func labelKind(state: MediaMenuState) -> MediaActionLabel.Kind? {
        switch id {
        case .play: return .play
        case .shuffle: return .shuffle
        case .toggleShuffle: return .toggleShuffle(isEnabled: state.isShuffleEnabled)
        case .repeatAll: return .repeatAll(isEnabled: state.repeatMode == .all)
        case .repeatOne: return .repeatOne(isEnabled: state.repeatMode == .one)
        case .radio: return .radio
        case .playNext: return .playNext
        case .playLast: return .playLast
        case .addToRecentPlaylist:
            guard let title = state.recentPlaylistTitle else { return nil }
            return .addToRecentPlaylist(title)
        case .addToPlaylist: return .addToPlaylist
        case .goToAlbum: return .goToAlbum
        case .goToArtist: return .goToArtist
        case .editMetadata: return .editMetadata
        case .rename: return .rename
        case .renameAll: return .renameAll
        case .editPlaylist: return .editPlaylist
        case .download: return .download(isDownloaded: state.isDownloaded)
        case .downloadAll: return .downloadAll
        case .removeDownloads: return .removeDownloads
        case .favorite: return .favorite(isFavorited: state.isFavorited, usesFilledIcon: false)
        case .pin: return .pin(isPinned: state.isPinned)
        case .unpinAll: return .unpinAll
        case .shareLink: return .shareLink
        case .shareAudioFile: return .shareAudioFile
        case .removeFromQueue: return .removeFromQueue
        case .deleteTrack: return .deleteTrack
        case .deleteAlbum: return .deleteAlbum
        case .deletePlaylist: return .deletePlaylist
        case .deleteAll: return .deleteAll
        }
    }
}

struct SwiftUIMediaMenuRenderer: View {
    let sections: [MediaMenuSection]
    let state: MediaMenuState
    let handlers: MediaMenuHandlers

    var body: some View {
        ForEach(renderableSections, id: \.id) { section in
            Section {
                ForEach(section.actions, id: \.id) { descriptor in
                    if let handler = handlers.handler(for: descriptor.id),
                       let labelKind = descriptor.labelKind(state: state) {
                        Button(role: descriptor.role == .destructive ? .destructive : nil) {
                            handler()
                        } label: {
                            MediaActionLabel(kind: labelKind)
                        }
                    }
                }
            }
        }
    }

    private var renderableSections: [MediaMenuSection] {
        sections.compactMap { section in
            let actions = section.actions.filter { descriptor in
                handlers.handler(for: descriptor.id) != nil && descriptor.label(state: state) != nil
            }
            return actions.isEmpty ? nil : MediaMenuSection(id: section.id, actions: actions)
        }
    }
}

#if canImport(UIKit)
enum UIKitMediaMenuRenderer {
    static func contextMenu(
        sections: [MediaMenuSection],
        state: MediaMenuState,
        handlers: MediaMenuHandlers
    ) -> UIMenu? {
        let children = renderableSections(sections, state: state, handlers: handlers).map { section in
            UIMenu(
                title: "",
                options: .displayInline,
                children: section.actions.compactMap { descriptor in
                    guard let handler = handlers.handler(for: descriptor.id),
                          let label = descriptor.label(state: state) else { return nil }
                    return UIAction(
                        title: label.title,
                        image: UIImage(systemName: label.systemImage),
                        attributes: descriptor.role == .destructive ? .destructive : []
                    ) { _ in
                        handler()
                    }
                }
            )
        }

        return children.isEmpty ? nil : UIMenu(children: children)
    }

    private static func renderableSections(
        _ sections: [MediaMenuSection],
        state: MediaMenuState,
        handlers: MediaMenuHandlers
    ) -> [MediaMenuSection] {
        sections.compactMap { section in
            let actions = section.actions.filter { descriptor in
                handlers.handler(for: descriptor.id) != nil && descriptor.label(state: state) != nil
            }
            return actions.isEmpty ? nil : MediaMenuSection(id: section.id, actions: actions)
        }
    }
}
#endif

#if canImport(AppKit)
enum AppKitMediaMenuRenderer {
    static func contextMenu(
        sections: [MediaMenuSection],
        state: MediaMenuState,
        handlers: MediaMenuHandlers
    ) -> NSMenu? {
        let menu = NSMenu()

        for section in renderableSections(sections, state: state, handlers: handlers) {
            addSeparatorIfNeeded(to: menu)
            for descriptor in section.actions {
                guard let handler = handlers.handler(for: descriptor.id),
                      let label = descriptor.label(state: state) else { continue }
                let item = AppKitClosureMenuItem(title: label.title, action: handler)
                item.image = NSImage(systemSymbolName: label.systemImage, accessibilityDescription: label.title)
                menu.addItem(item)
            }
        }

        return menu.items.isEmpty ? nil : menu
    }

    private static func renderableSections(
        _ sections: [MediaMenuSection],
        state: MediaMenuState,
        handlers: MediaMenuHandlers
    ) -> [MediaMenuSection] {
        sections.compactMap { section in
            let actions = section.actions.filter { descriptor in
                handlers.handler(for: descriptor.id) != nil && descriptor.label(state: state) != nil
            }
            return actions.isEmpty ? nil : MediaMenuSection(id: section.id, actions: actions)
        }
    }

    private static func addSeparatorIfNeeded(to menu: NSMenu) {
        guard let last = menu.items.last, !last.isSeparatorItem else { return }
        menu.addItem(.separator())
    }
}

private final class AppKitClosureMenuItem: NSMenuItem {
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
