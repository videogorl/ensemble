import EnsembleCore

public enum SidebarSelection: Hashable {
    case library(TabItem)
    case playlist(id: String, sourceKey: String?)
    case mergedPlaylist(title: String, isSmart: Bool)
    case pin(id: String, sourceKey: String?, type: PinnedItemType)
    case hidden

    /// Map sidebar section to the corresponding TabItem for NavigationCoordinator sync.
    var correspondingTab: TabItem? {
        switch self {
        case .library(let tab):
            return tab
        case .playlist, .mergedPlaylist:
            return .playlists
        case .pin(_, _, let type):
            switch type {
            case .artist: return .artists
            case .album: return .albums
            case .playlist: return .playlists
            }
        case .hidden:
            return nil
        }
    }

    /// A sidebar-only root becomes the first pushed destination in compact tabs.
    var compactDestination: NavigationCoordinator.Destination? {
        switch self {
        case .library: return nil
        case .playlist(let id, let sourceKey): return .playlist(id: id, sourceKey: sourceKey)
        case .mergedPlaylist(let title, let isSmart): return .mergedPlaylist(title: title, isSmart: isSmart)
        case .pin(let id, let sourceKey, let type):
            switch type {
            case .artist: return .artist(id: id, sourceKey: sourceKey)
            case .album: return .album(id: id, sourceKey: sourceKey)
            case .playlist: return .playlist(id: id, sourceKey: sourceKey)
            }
        case .hidden: return .hidden
        }
    }

    var isPinnedDetailSelection: Bool {
        if case .pin = self {
            return true
        }
        return false
    }

    static func selection(
        for destination: NavigationCoordinator.Destination,
        fallback: SidebarSelection?
    ) -> SidebarSelection {
        switch destination {
        case .displayArtist, .artistNamed, .artistDetail, .artist:
            return .library(.artists)
        case .displayGenre:
            return .library(.genres)
        case .album, .albumDetail, .song:
            return .library(.albums)
        case .playlist(let id, let sourceKey):
            return .playlist(id: id, sourceKey: sourceKey)
        case .playlistDetail(let playlist, _):
            return .playlist(id: playlist.id, sourceKey: playlist.sourceCompositeKey)
        case .mergedPlaylist(let title, let isSmart):
            return .mergedPlaylist(title: title, isSmart: isSmart)
        case .moodTracks:
            return .library(.home)
        case .hidden:
            return .hidden
        case .searchResults:
            return .library(.search)
        case .view(let tab):
            switch tab {
            case .home, .songs, .artists, .albums, .genres, .playlists, .favorites, .search:
                return .library(tab)
            case .downloads, .settings:
                return fallback ?? .library(.home)
            }
        }
    }
}
