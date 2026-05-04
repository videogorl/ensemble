import EnsembleCore
import Foundation

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
enum MediaMenuActionID: String, Equatable {
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

enum MediaMenuSectionID: String, Equatable {
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
