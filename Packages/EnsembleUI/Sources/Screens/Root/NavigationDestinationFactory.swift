import EnsembleCore
import SwiftUI

struct NavigationDestinationFactory {
    @MainActor
    static func tabContent(
        for tab: TabItem,
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        homeVM: HomeViewModel? = nil,
        searchVM: SearchViewModel,
        pinnedVM: PinnedViewModel? = nil,
        playlistsVM: PlaylistViewModel,
        mediaNavigationNamespace: Namespace.ID? = nil,
        isMoreRoot: Bool = false
    ) -> AnyView {
        AnyView(NavigationTabContentView(
            tab: tab,
            libraryVM: libraryVM,
            nowPlayingVM: nowPlayingVM,
            homeVM: homeVM,
            searchVM: searchVM,
            pinnedVM: pinnedVM,
            playlistsVM: playlistsVM,
            mediaNavigationNamespace: mediaNavigationNamespace,
            isMoreRoot: isMoreRoot
        ))
    }

    @MainActor
    static func destinationContent(
        for destination: NavigationCoordinator.Destination,
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        homeVM: HomeViewModel? = nil,
        searchVM: SearchViewModel,
        pinnedVM: PinnedViewModel? = nil,
        playlistsVM: PlaylistViewModel,
        mediaNavigationNamespace: Namespace.ID? = nil
    ) -> AnyView {
        switch destination {
        case .displayArtist(let id):
            if let displayArtist = displayArtist(for: id, libraryVM: libraryVM) {
                return AnyView(ArtistDetailView(displayArtist: displayArtist, nowPlayingVM: nowPlayingVM))
            } else {
                return AnyView(EnsembleStateScaffold(kind: .empty, title: "Artist not found"))
            }
        case .artistNamed(let name, let fallbackID, let sourceKey, let includesHidden):
            if let displayArtist = displayArtist(named: name, libraryVM: libraryVM) {
                return AnyView(
                    ArtistDetailView(
                        displayArtist: displayArtist,
                        nowPlayingVM: nowPlayingVM,
                        includesHidden: includesHidden
                    )
                    .hiddenPlaybackScope(nowPlayingVM, isEnabled: includesHidden)
                )
            }
            if let fallbackID {
                return AnyView(
                    ArtistDetailLoader(
                        artistId: fallbackID,
                        artistSourceKey: sourceKey,
                        nowPlayingVM: nowPlayingVM,
                        includesHidden: includesHidden
                    )
                    .hiddenPlaybackScope(nowPlayingVM, isEnabled: includesHidden)
                )
            }
            return AnyView(EnsembleStateScaffold(kind: .empty, title: "Artist not found"))
        case .displayGenre(let id):
            if let displayGenre = displayGenre(for: id, libraryVM: libraryVM) {
                return AnyView(GenreDetailContentView(
                    libraryVM: libraryVM,
                    genre: displayGenre,
                    nowPlayingVM: nowPlayingVM,
                    presentationStyle: .navigationPage
                ))
            } else {
                return AnyView(EnsembleStateScaffold(kind: .empty, title: "Genre not found"))
            }
        case .artistDetail(let artist, let includesHidden):
            return AnyView(
                ArtistDetailView(
                    artist: artist,
                    nowPlayingVM: nowPlayingVM,
                    includesHidden: includesHidden
                )
                .hiddenPlaybackScope(nowPlayingVM, isEnabled: includesHidden)
            )
        case .artist(let id, let sourceKey):
            return AnyView(ArtistDetailLoader(artistId: id, artistSourceKey: sourceKey, nowPlayingVM: nowPlayingVM))
        case .album(let id, let sourceKey):
            return AnyView(AlbumDetailLoader(albumId: id, albumSourceKey: sourceKey, nowPlayingVM: nowPlayingVM))
        case .albumDetail(let album, let includesHidden):
            let detailView = AlbumDetailView(
                album: album,
                nowPlayingVM: nowPlayingVM,
                includesHidden: includesHidden
            )
            .hiddenPlaybackScope(nowPlayingVM, isEnabled: includesHidden)
            #if os(iOS)
            if #available(iOS 18.0, *), let mediaNavigationNamespace {
                return AnyView(
                    detailView.navigationTransition(
                        .zoom(sourceID: album.sourceScopedID, in: mediaNavigationNamespace)
                    )
                )
            }
            #endif
            return AnyView(detailView)
        case .song(let id, let sourceKey):
            return AnyView(SongPermalinkLoader(songId: id, songSourceKey: sourceKey, nowPlayingVM: nowPlayingVM))
        case .playlist(let id, let sourceKey):
            return AnyView(PlaylistDetailLoader(playlistId: id, playlistSourceKey: sourceKey, nowPlayingVM: nowPlayingVM))
        case .playlistDetail(let playlist, let includesHidden):
            return AnyView(
                PlaylistDetailView(
                    playlist: playlist,
                    nowPlayingVM: nowPlayingVM,
                    includesHidden: includesHidden
                )
                .hiddenPlaybackScope(nowPlayingVM, isEnabled: includesHidden)
            )
        case .mergedPlaylist(let title, let isSmart):
            return AnyView(MergedPlaylistDetailLoader(title: title, isSmart: isSmart, nowPlayingVM: nowPlayingVM))
        case .moodTracks(let mood):
            return AnyView(MoodTracksView(mood: mood, nowPlayingVM: nowPlayingVM))
        case .hidden:
            return AnyView(HiddenMediaView(nowPlayingVM: nowPlayingVM))
        case .searchResults(let section):
            return AnyView(SearchView(
                nowPlayingVM: nowPlayingVM,
                viewModel: searchVM,
                pinnedVM: pinnedVM,
                resultSection: section
            ))
        case .view(let tab):
            return AnyView(NavigationTabContentView(
                tab: tab,
                libraryVM: libraryVM,
                nowPlayingVM: nowPlayingVM,
                homeVM: homeVM,
                searchVM: searchVM,
                pinnedVM: pinnedVM,
                playlistsVM: playlistsVM,
                mediaNavigationNamespace: mediaNavigationNamespace,
                isMoreRoot: false
            ))
        }
    }

    @MainActor
    private static func displayArtist(for id: String, libraryVM: LibraryViewModel) -> DisplayArtist? {
        if let displayArtist = libraryVM.artistBrowseSnapshot.displayArtists.first(where: { $0.id == id }) {
            return displayArtist
        }

        return DisplayArtist.group(libraryVM.artists).first { $0.id == id }
    }

    @MainActor
    private static func displayArtist(named name: String, libraryVM: LibraryViewModel) -> DisplayArtist? {
        let normalizedName = DisplayArtist.normalizedName(name)
        return libraryVM.artistBrowseSnapshot.displayArtists.first {
            DisplayArtist.normalizedName($0.name) == normalizedName
        } ?? DisplayArtist.group(libraryVM.artists).first {
            DisplayArtist.normalizedName($0.name) == normalizedName
        }
    }

    @MainActor
    private static func displayGenre(for id: String, libraryVM: LibraryViewModel) -> DisplayGenre? {
        libraryVM.immediateGenreBrowseSnapshot.displayGenres.first { $0.id == id }
    }
}

private extension View {
    func hiddenPlaybackScope(_ nowPlayingVM: NowPlayingViewModel, isEnabled: Bool = true) -> some View {
        onAppear {
            if isEnabled { nowPlayingVM.beginHiddenPlaybackScope() }
        }
        .onDisappear {
            if isEnabled { nowPlayingVM.endHiddenPlaybackScope() }
        }
    }
}

private struct NavigationTabContentView: View {
    let tab: TabItem
    let libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    let homeVM: HomeViewModel?
    let searchVM: SearchViewModel
    let pinnedVM: PinnedViewModel?
    let playlistsVM: PlaylistViewModel
    let mediaNavigationNamespace: Namespace.ID?
    let isMoreRoot: Bool

    var body: some View {
        if isMoreRoot {
            MoreView()
        } else {
            tabBody
        }
    }

    @ViewBuilder
    private var tabBody: some View {
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
            PlaylistsView(nowPlayingVM: nowPlayingVM, viewModel: playlistsVM)
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
