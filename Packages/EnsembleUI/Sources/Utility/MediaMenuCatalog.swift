import EnsembleDesignTokens
import EnsembleCore
import EnsembleDomain
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
    case playlistTrack(canRemove: Bool)
    case queue(canRemove: Bool)
    case history
    case stageFlow

    var allowsTrackEditing: Bool {
        switch self {
        case .library, .detail, .playlistTrack:
            return true
        case .search, .pinned, .sidebar, .miniPlayer, .nowPlayingControls, .queue, .history, .stageFlow:
            return false
        }
    }

    var allowsPlaylistManagement: Bool {
        switch self {
        case .library, .detail, .pinned, .sidebar:
            return true
        case .search, .miniPlayer, .nowPlayingControls, .playlistTrack, .queue, .history, .stageFlow:
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
    case addToLibrary
    case addToRecentPlaylist
    case addToPlaylist
    case goToAlbum
    case goToArtist
    case getInfo
    case editMetadata
    case rename
    case editPlaylist
    case download
    case favorite
    case pin
    case unpinAll
    case toggleHidden
    case shareEnsembleLink
    case shareLink
    case shareAudioFile
    case removeFromPlaylist
    case removeFromQueue
    case deleteTrack
    case deleteAlbum
    case deletePlaylist
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
    let availability: EnsembleDomain.MusicItemActionAvailability

    init(
        _ id: MediaMenuActionID,
        role: Role = .normal,
        availability: EnsembleDomain.MusicItemActionAvailability = .available
    ) {
        self.id = id
        self.role = role
        self.availability = availability
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
    var addToLibrary: (() -> Void)?
    var addToRecentPlaylist: (() -> Void)?
    var addToPlaylist: (() -> Void)?
    var goToAlbum: (() -> Void)?
    var goToArtist: (() -> Void)?
    var getInfo: (() -> Void)?
    var editMetadata: (() -> Void)?
    var rename: (() -> Void)?
    var editPlaylist: (() -> Void)?
    var download: (() -> Void)?
    var favorite: (() -> Void)?
    var pin: (() -> Void)?
    var unpinAll: (() -> Void)?
    var shareEnsembleLink: (() -> Void)?
    var shareLink: (() -> Void)?
    var shareAudioFile: (() -> Void)?
    var removeFromPlaylist: (() -> Void)?
    var removeFromQueue: (() -> Void)?
    var deleteTrack: (() -> Void)?
    var deleteAlbum: (() -> Void)?
    var deletePlaylist: (() -> Void)?
    var toggleHidden: (() -> Void)?

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
        case .addToLibrary: return addToLibrary
        case .addToRecentPlaylist: return addToRecentPlaylist
        case .addToPlaylist: return addToPlaylist
        case .goToAlbum: return goToAlbum
        case .goToArtist: return goToArtist
        case .getInfo: return getInfo
        case .editMetadata: return editMetadata
        case .rename: return rename
        case .editPlaylist: return editPlaylist
        case .download: return download
        case .favorite: return favorite
        case .pin: return pin
        case .unpinAll: return unpinAll
        case .toggleHidden: return toggleHidden
        case .shareEnsembleLink: return shareEnsembleLink
        case .shareLink: return shareLink
        case .shareAudioFile: return shareAudioFile
        case .removeFromPlaylist: return removeFromPlaylist
        case .removeFromQueue: return removeFromQueue
        case .deleteTrack: return deleteTrack
        case .deleteAlbum: return deleteAlbum
        case .deletePlaylist: return deletePlaylist
        }
    }
}

/// Dynamic menu state that affects action availability or labels without
/// changing the catalog's section policy.
struct MediaMenuAvailability: Equatable {
    var hasRecentPlaylist = false
    var canAddToLibrary = false
    var canAddToRecentPlaylist = true
    var canGoToAlbum = false
    var canGoToArtist = false
    var canGetInfo = true
    var canShareEnsembleLink = true
    var canShareLink = true
    var canShareAudioFile = false
    var canFavorite = true
    var canDownload = true
    var canPin = true
    var canEditMetadata = true
    var canDelete = true
    var canRename = true
    var canEditPlaylist = true
    var canRemoveFromPlaylist = true
    var canRemoveFromQueue = true
    var itemActions: [MediaMenuActionID: EnsembleDomain.MusicItemActionAvailability] = [:]

    static let full = MediaMenuAvailability(
        hasRecentPlaylist: true,
        canAddToLibrary: true,
        canAddToRecentPlaylist: true,
        canGoToAlbum: true,
        canGoToArtist: true,
        canGetInfo: true,
        canShareEnsembleLink: true,
        canShareLink: true,
        canShareAudioFile: true,
        canFavorite: true,
        canDownload: true,
        canPin: true,
        canEditMetadata: true,
        canDelete: true,
        canRename: true,
        canEditPlaylist: true,
        canRemoveFromPlaylist: true,
        canRemoveFromQueue: true
    )
}

/// Runtime values used by labels once an action is selected by the catalog.
struct MediaMenuState: Equatable {
    var recentPlaylistTitle: String?
    var isFavorited = false
    var isDownloaded = false
    var isPinned = false
    var isHidden = false
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
        let sections: [MediaMenuSection]
        switch itemKind {
        case .track:
            sections = trackSections(context: context, availability: availability)
        case .album:
            sections = albumSections(context: context, availability: availability)
        case .artist:
            sections = artistSections(context: context, availability: availability)
        case .playlist(let isSmart):
            sections = playlistSections(isSmart: isSmart, context: context, availability: availability)
        case .mergedPlaylist(let isSmart):
            sections = mergedPlaylistSections(isSmart: isSmart, context: context, availability: availability)
        }
        return sections.map { section in
            MediaMenuSection(
                id: section.id,
                actions: section.actions.map { descriptor in
                    MediaMenuActionDescriptor(
                        descriptor.id,
                        role: descriptor.role,
                        availability: availability.itemActions[descriptor.id] ?? .available
                    )
                }
            )
        }
    }

    static func renderableSections(
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

    private static func trackSections(
        context: MediaMenuContext,
        availability: MediaMenuAvailability
    ) -> [MediaMenuSection] {
        var sections: [MediaMenuSection] = [
            section(.playback, [.playNext, .playLast])
        ]

        var playlistActions: [MediaMenuActionID] = []
        if availability.canAddToLibrary {
            playlistActions.append(.addToLibrary)
        }
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
        if availability.canShareEnsembleLink {
            shareActions.append(.shareEnsembleLink)
        }
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

        if case .playlistTrack(let canRemove) = context, canRemove, availability.canRemoveFromPlaylist {
            sections.append(section(.destructive, [.removeFromPlaylist], role: .destructive))
        }

        if case .queue(let canRemove) = context, canRemove, availability.canRemoveFromQueue {
            sections.append(section(.destructive, [.removeFromQueue], role: .destructive))
        }

        var managementActions: [MediaMenuActionID] = []
        if availability.canGetInfo {
            managementActions.append(.getInfo)
        }
        if context.allowsTrackEditing, availability.canEditMetadata {
            managementActions.append(.editMetadata)
        }
        managementActions.append(.toggleHidden)
        if context.allowsTrackEditing, availability.canDelete {
            managementActions.append(.deleteTrack)
        }
        sections.append(section(.management, managementActions, destructive: [.deleteTrack]))
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

        var navigationActions: [MediaMenuActionID] = []
        if availability.canGoToArtist {
            navigationActions.append(.goToArtist)
        }
        sections.append(section(.navigation, navigationActions))

        var shareActions: [MediaMenuActionID] = []
        if availability.canShareEnsembleLink {
            shareActions.append(.shareEnsembleLink)
        }
        if availability.canShareLink {
            shareActions.append(.shareLink)
        }
        if !shareActions.isEmpty {
            sections.append(section(.sharing, shareActions))
        }

        var offlinePinning: [MediaMenuActionID] = []
        if availability.canDownload {
            offlinePinning.append(.download)
        }
        if availability.canPin {
            offlinePinning.append(.pin)
        }
        sections.append(section(.offline, offlinePinning))

        var management: [MediaMenuActionID] = []
        if availability.canGetInfo {
            management.append(.getInfo)
        }
        if (context.allowsPlaylistManagement || context.allowsTrackEditing), availability.canEditMetadata {
            management.append(.editMetadata)
        }
        management.append(.toggleHidden)
        if (context.allowsPlaylistManagement || context.allowsTrackEditing), availability.canDelete {
            management.append(.deleteAlbum)
        }
        sections.append(section(.management, management, destructive: [.deleteAlbum]))
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

        if availability.canShareEnsembleLink {
            sections.append(section(.sharing, [.shareEnsembleLink]))
        }

        var management: [MediaMenuActionID] = []
        if (context.allowsPlaylistManagement || context.allowsTrackEditing), availability.canEditMetadata {
            management.append(.editMetadata)
        }
        management.append(.toggleHidden)
        sections.append(section(.management, management))
        return sections.filter { !$0.actions.isEmpty }
    }

    private static func playlistSections(
        isSmart _: Bool,
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

        if availability.canShareEnsembleLink {
            sections.append(section(.sharing, [.shareEnsembleLink]))
        }

        var management: [MediaMenuActionID] = []
        if availability.canGetInfo {
            management.append(.getInfo)
        }
        if context.allowsPlaylistManagement, availability.canRename {
            management.append(.rename)
        }
        if context.allowsPlaylistManagement, availability.canEditPlaylist {
            management.append(.editPlaylist)
        }
        management.append(.toggleHidden)
        if context.allowsPlaylistManagement, availability.canDelete {
            management.append(.deletePlaylist)
        }
        sections.append(section(.management, management, destructive: [.deletePlaylist]))
        return sections.filter { !$0.actions.isEmpty }
    }

    private static func mergedPlaylistSections(
        isSmart _: Bool,
        context: MediaMenuContext,
        availability: MediaMenuAvailability
    ) -> [MediaMenuSection] {
        var sections = [
            section(.playback, [.play, .shuffle, .playNext, .playLast]),
            section(.offline, [.download])
        ]

        if context == .pinned || context == .sidebar {
            sections.append(section(.pinning, [.unpinAll], role: .destructive))
        }

        if availability.canShareEnsembleLink {
            sections.append(section(.sharing, [.shareEnsembleLink]))
        }

        var management: [MediaMenuActionID] = []
        if context.allowsPlaylistManagement, availability.canRename {
            management.append(.rename)
        }
        management.append(.toggleHidden)
        if context.allowsPlaylistManagement, availability.canDelete {
            management.append(.deletePlaylist)
        }
        sections.append(section(.management, management, destructive: [.deletePlaylist]))
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
            actions: sharedOrdered(actions).map { action in
                MediaMenuActionDescriptor(
                    action,
                    role: destructive.contains(action) ? .destructive : role
                )
            }
        )
    }

    private static func sharedOrdered(_ actions: [MediaMenuActionID]) -> [MediaMenuActionID] {
        let rank = Dictionary(
            uniqueKeysWithValues: EnsembleMediaActionCatalog.ordered.enumerated().map { ($1.action, $0) }
        )
        var shared = actions.filter { $0.ensembleAction != nil }.sorted {
            ($0.ensembleAction.flatMap { rank[$0] } ?? .max)
                < ($1.ensembleAction.flatMap { rank[$0] } ?? .max)
        }.makeIterator()
        return actions.map { action in
            action.ensembleAction == nil ? action : shared.next() ?? action
        }
    }
}

private extension MediaMenuActionID {
    var ensembleAction: EnsembleMediaAction? {
        switch self {
        case .play: .play
        case .shuffle: .shuffle
        case .radio: .radio
        case .playNext: .playNext
        case .playLast: .playLast
        case .addToPlaylist: .addToPlaylist
        case .addToRecentPlaylist: .addToRecentPlaylist
        case .favorite: .favorite
        case .pin: .pin
        case .goToAlbum: .goToAlbum
        case .goToArtist: .goToArtist
        case .shareEnsembleLink: .share
        case .deleteTrack, .deleteAlbum, .deletePlaylist: .delete
        default: nil
        }
    }
}

extension MediaMenuActionDescriptor {
    func label(state: MediaMenuState) -> MediaMenuLabel? {
        if let sharedDescriptor,
           ![.addToRecentPlaylist, .favorite, .pin, .delete].contains(sharedDescriptor.action) {
            return MediaMenuLabel(
                title: sharedDescriptor.title,
                systemImage: sharedDescriptor.systemImage
            )
        }
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
        case .addToLibrary:
            return MediaMenuLabel(title: "Add to Library", systemImage: "text.badge.plus")
        case .addToRecentPlaylist:
            guard let title = state.recentPlaylistTitle else { return nil }
            return MediaMenuLabel(title: "Add to \(title)", systemImage: EnsembleDesign.Icon.recentPlaylist)
        case .addToPlaylist:
            return MediaMenuLabel(title: "Add to Playlist…", systemImage: EnsembleDesign.Icon.addToPlaylist)
        case .goToAlbum:
            return MediaMenuLabel(title: "Go to Album", systemImage: EnsembleDesign.Icon.album)
        case .goToArtist:
            return MediaMenuLabel(title: "Go to Artist", systemImage: EnsembleDesign.Icon.artist)
        case .getInfo:
            return MediaMenuLabel(title: "Get Info…", systemImage: EnsembleDesign.Icon.info)
        case .editMetadata:
            return MediaMenuLabel(title: "Edit Metadata…", systemImage: EnsembleDesign.Icon.edit)
        case .rename:
            return MediaMenuLabel(title: "Rename…", systemImage: EnsembleDesign.Icon.edit)
        case .editPlaylist:
            return MediaMenuLabel(title: "Edit Playlist", systemImage: EnsembleDesign.Icon.editPlaylist)
        case .download:
            return MediaMenuLabel(
                title: state.isDownloaded ? "Remove Download" : "Download",
                systemImage: state.isDownloaded ? EnsembleDesign.Icon.removeDownload : EnsembleDesign.Icon.download
            )
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
        case .toggleHidden:
            return MediaMenuLabel(
                title: state.isHidden ? "Unhide" : "Hide",
                systemImage: state.isHidden ? "eye" : "eye.slash"
            )
        case .shareEnsembleLink:
            return MediaMenuLabel(title: "Share Ensemble Link…", systemImage: EnsembleDesign.Icon.shareLink)
        case .shareLink:
            return MediaMenuLabel(title: "Share Link…", systemImage: EnsembleDesign.Icon.shareLink)
        case .shareAudioFile:
            return MediaMenuLabel(title: "Share Audio File…", systemImage: EnsembleDesign.Icon.shareAudioFile)
        case .removeFromPlaylist:
            return MediaMenuLabel(title: "Remove from Playlist", systemImage: EnsembleDesign.Icon.removeFromPlaylist)
        case .removeFromQueue:
            return MediaMenuLabel(title: "Remove from Queue", systemImage: EnsembleDesign.Icon.removeCircle)
        case .deleteTrack:
            return MediaMenuLabel(title: "Delete Track", systemImage: EnsembleDesign.Icon.delete)
        case .deleteAlbum:
            return MediaMenuLabel(title: "Delete Album", systemImage: EnsembleDesign.Icon.delete)
        case .deletePlaylist:
            return MediaMenuLabel(title: "Delete Playlist", systemImage: EnsembleDesign.Icon.delete)
        }
    }

    private var sharedDescriptor: EnsembleMediaActionDescriptor? {
        guard let action = id.ensembleAction else { return nil }
        return EnsembleMediaActionCatalog.ordered.first { $0.action == action }
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
        case .addToLibrary: return .addToLibrary
        case .addToRecentPlaylist:
            guard let title = state.recentPlaylistTitle else { return nil }
            return .addToRecentPlaylist(title)
        case .addToPlaylist: return .addToPlaylist
        case .goToAlbum: return .goToAlbum
        case .goToArtist: return .goToArtist
        case .getInfo: return .getInfo
        case .editMetadata: return .editMetadata
        case .rename: return .rename
        case .editPlaylist: return .editPlaylist
        case .download: return .download(isDownloaded: state.isDownloaded)
        case .favorite: return .favorite(isFavorited: state.isFavorited, usesFilledIcon: false)
        case .pin: return .pin(isPinned: state.isPinned)
        case .unpinAll: return .unpinAll
        case .toggleHidden: return .toggleHidden(isHidden: state.isHidden)
        case .shareEnsembleLink: return .shareEnsembleLink
        case .shareLink: return .shareLink
        case .shareAudioFile: return .shareAudioFile
        case .removeFromPlaylist: return .removeFromPlaylist
        case .removeFromQueue: return .removeFromQueue
        case .deleteTrack: return .deleteTrack
        case .deleteAlbum: return .deleteAlbum
        case .deletePlaylist: return .deletePlaylist
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
                        .disabled(!descriptor.availability.isAvailable)
                        .accessibilityHint(descriptor.availability.reason ?? "")
                    }
                }
            }
        }
    }

    private var renderableSections: [MediaMenuSection] {
        MediaMenuCatalog.renderableSections(sections, state: state, handlers: handlers)
    }
}

#if canImport(UIKit)
enum UIKitMediaMenuRenderer {
    static func contextMenu(
        sections: [MediaMenuSection],
        state: MediaMenuState,
        handlers: MediaMenuHandlers
    ) -> UIMenu? {
        let children = MediaMenuCatalog.renderableSections(sections, state: state, handlers: handlers).map { section in
            UIMenu(
                title: "",
                options: .displayInline,
                children: section.actions.compactMap { descriptor in
                    guard let handler = handlers.handler(for: descriptor.id),
                          let label = descriptor.label(state: state) else { return nil }
                    var attributes: UIMenuElement.Attributes = descriptor.role == .destructive ? .destructive : []
                    if !descriptor.availability.isAvailable {
                        attributes.insert(.disabled)
                    }
                    return UIAction(
                        title: label.title,
                        subtitle: descriptor.availability.reason,
                        image: UIImage(systemName: label.systemImage),
                        attributes: attributes
                    ) { _ in
                        handler()
                    }
                }
            )
        }

        return children.isEmpty ? nil : UIMenu(children: children)
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

        for section in MediaMenuCatalog.renderableSections(sections, state: state, handlers: handlers) {
            addSeparatorIfNeeded(to: menu)
            for descriptor in section.actions {
                guard let handler = handlers.handler(for: descriptor.id),
                      let label = descriptor.label(state: state) else { continue }
                let item = AppKitClosureMenuItem(title: label.title, action: handler)
                item.image = NSImage(systemSymbolName: label.systemImage, accessibilityDescription: label.title)
                item.isEnabled = descriptor.availability.isAvailable
                item.toolTip = descriptor.availability.reason
                menu.addItem(item)
            }
        }

        return menu.items.isEmpty ? nil : menu
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
