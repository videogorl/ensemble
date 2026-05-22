import EnsembleCore
import SwiftUI

struct NavigationDestinationFactory {
    @MainActor
    @ViewBuilder
    static func tabContent(
        for tab: TabItem,
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        homeVM: HomeViewModel? = nil,
        searchVM: SearchViewModel,
        pinnedVM: PinnedViewModel? = nil,
        isMoreRoot: Bool = false
    ) -> some View {
        if isMoreRoot {
            MoreView(
                libraryVM: libraryVM,
                nowPlayingVM: nowPlayingVM
            )
        } else {
            switch tab {
            case .home:
                HomeView(nowPlayingVM: nowPlayingVM, viewModel: homeVM)
            case .songs:
                SongsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
            case .artists:
                ArtistsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
            case .albums:
                AlbumsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
            case .genres:
                GenresView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
            case .playlists:
                PlaylistsView(nowPlayingVM: nowPlayingVM)
            case .favorites:
                FavoritesView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
            case .search:
                SearchView(nowPlayingVM: nowPlayingVM, viewModel: searchVM, pinnedVM: pinnedVM)
            case .downloads:
                DownloadsView(nowPlayingVM: nowPlayingVM)
            case .settings:
                ProfileView()
            }
        }
    }

    @MainActor
    @ViewBuilder
    static func destinationContent(
        for destination: NavigationCoordinator.Destination,
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        homeVM: HomeViewModel? = nil,
        searchVM: SearchViewModel,
        pinnedVM: PinnedViewModel? = nil
    ) -> some View {
        switch destination {
        case .displayArtist(let id):
            if let displayArtist = displayArtist(for: id, libraryVM: libraryVM) {
                ArtistDetailView(displayArtist: displayArtist, nowPlayingVM: nowPlayingVM)
            } else {
                EnsembleStateScaffold(kind: .empty, title: "Artist not found")
            }
        case .artist(let id, let sourceKey):
            ArtistDetailLoader(artistId: id, artistSourceKey: sourceKey, nowPlayingVM: nowPlayingVM)
        case .album(let id, let sourceKey):
            AlbumDetailLoader(albumId: id, albumSourceKey: sourceKey, nowPlayingVM: nowPlayingVM)
        case .albumDetail(let album):
            AlbumDetailView(album: album, nowPlayingVM: nowPlayingVM)
        case .playlist(let id, let sourceKey):
            PlaylistDetailLoader(playlistId: id, playlistSourceKey: sourceKey, nowPlayingVM: nowPlayingVM)
        case .mergedPlaylist(let title, let isSmart):
            MergedPlaylistDetailLoader(title: title, isSmart: isSmart, nowPlayingVM: nowPlayingVM)
        case .moodTracks(let mood):
            MoodTracksView(mood: mood, nowPlayingVM: nowPlayingVM)
        case .view(let tab):
            tabContent(
                for: tab,
                libraryVM: libraryVM,
                nowPlayingVM: nowPlayingVM,
                homeVM: homeVM,
                searchVM: searchVM,
                pinnedVM: pinnedVM
            )
        }
    }

    @MainActor
    private static func displayArtist(for id: String, libraryVM: LibraryViewModel) -> DisplayArtist? {
        if let displayArtist = libraryVM.displayArtists.first(where: { $0.id == id }) {
            return displayArtist
        }

        return DisplayArtist.group(libraryVM.artists).first { $0.id == id }
    }
}
