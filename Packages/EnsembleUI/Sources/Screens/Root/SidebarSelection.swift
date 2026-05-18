import EnsembleCore

public enum SidebarSelection: Hashable {
    case library(TabItem)
    case playlist(id: String, sourceKey: String?)
    case mergedPlaylist(title: String, isSmart: Bool)
    case pin(id: String, sourceKey: String?, type: PinnedItemType)

    /// Map sidebar section to the corresponding TabItem for NavigationCoordinator sync.
    /// Returns nil for pinned items which don't map to a standard tab.
    var correspondingTab: TabItem? {
        switch self {
        case .library(let tab):
            return tab
        case .playlist, .mergedPlaylist:
            return .playlists
        case .pin:
            return nil
        }
    }

    static func selection(
        for destination: NavigationCoordinator.Destination,
        fallback: SidebarSelection?
    ) -> SidebarSelection {
        switch destination {
        case .displayArtist, .artist:
            return .library(.artists)
        case .album:
            return .library(.albums)
        case .playlist(let id, let sourceKey):
            return .playlist(id: id, sourceKey: sourceKey)
        case .mergedPlaylist(let title, let isSmart):
            return .mergedPlaylist(title: title, isSmart: isSmart)
        case .moodTracks:
            return .library(.home)
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
