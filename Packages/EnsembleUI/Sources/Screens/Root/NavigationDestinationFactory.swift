import EnsembleCore
import SwiftUI

struct NavigationDestinationFactory {
    @MainActor
    @ViewBuilder
    static func tabContent(
        for tab: TabItem,
        nowPlayingVM: NowPlayingViewModel,
        viewModels: RootScreenModels,
        mediaNavigationNamespace: Namespace.ID? = nil,
        isMoreRoot: Bool = false,
        isSelectedRoot: Bool = true
    ) -> some View {
        NavigationTabContentView(
            tab: tab,
            nowPlayingVM: nowPlayingVM,
            viewModels: viewModels,
            mediaNavigationNamespace: mediaNavigationNamespace,
            isMoreRoot: isMoreRoot,
            isSelectedRoot: isSelectedRoot
        )
    }

    @MainActor
    @ViewBuilder
    static func destinationContent(
        for destination: NavigationCoordinator.Destination,
        nowPlayingVM: NowPlayingViewModel,
        viewModels: RootScreenModels,
        mediaNavigationNamespace: Namespace.ID? = nil
    ) -> some View {
        let libraryVM = viewModels.library
        switch destination {
        case .displayArtist(let id):
            ArtistDetailLoader(request: .display(id: id), libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
        case .artistNamed(let name, let fallbackID, let sourceKey, let includesHidden):
            ArtistDetailLoader(
                request: .reference(id: fallbackID, name: name, sourceKey: sourceKey),
                libraryVM: libraryVM,
                nowPlayingVM: nowPlayingVM,
                includesHidden: includesHidden
            )
            .hiddenPlaybackScope(nowPlayingVM, isEnabled: includesHidden)
        case .displayGenre(let id):
            if let displayGenre = displayGenre(for: id, libraryVM: libraryVM) {
                GenreDetailContentView(
                    libraryVM: libraryVM,
                    genre: displayGenre,
                    nowPlayingVM: nowPlayingVM,
                    presentationStyle: .navigationPage
                )
            } else {
                EnsembleStateScaffold(kind: .empty, title: "Genre not found")
            }
        case .artistDetail(let artist, let includesHidden):
            let detailView = ArtistDetailLoader(
                request: .artist(artist),
                libraryVM: libraryVM,
                nowPlayingVM: nowPlayingVM,
                includesHidden: includesHidden
            )
            .hiddenPlaybackScope(nowPlayingVM, isEnabled: includesHidden)
            #if os(iOS)
            if #available(iOS 18.0, *), let mediaNavigationNamespace {
                detailView.navigationTransition(
                    .zoom(sourceID: artist.sourceScopedID, in: mediaNavigationNamespace)
                )
            } else {
                detailView
            }
            #else
            detailView
            #endif
        case .artist(let id, let sourceKey):
            ArtistDetailLoader(request: .reference(id: id, name: nil, sourceKey: sourceKey), libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
        case .album(let id, let sourceKey, let selectedTrackId):
            AlbumDetailLoader(albumId: id, albumSourceKey: sourceKey, selectedTrackId: selectedTrackId, nowPlayingVM: nowPlayingVM)
        case .albumDetail(let displayAlbum, let includesHidden, let selectedTrackId):
            let detailView = AlbumDetailView(
                displayAlbum: displayAlbum,
                nowPlayingVM: nowPlayingVM,
                selectedTrackId: selectedTrackId,
                includesHidden: includesHidden
            )
            .hiddenPlaybackScope(nowPlayingVM, isEnabled: includesHidden)
            #if os(iOS)
            if #available(iOS 18.0, *), let mediaNavigationNamespace {
                detailView.navigationTransition(
                    .zoom(sourceID: displayAlbum.id, in: mediaNavigationNamespace)
                )
            } else {
                detailView
            }
            #else
            detailView
            #endif
        case .song(let id, let sourceKey):
            SongPermalinkLoader(songId: id, songSourceKey: sourceKey, nowPlayingVM: nowPlayingVM)
        case .playlist(let id, let sourceKey):
            PlaylistDetailLoader(playlistId: id, playlistSourceKey: sourceKey, nowPlayingVM: nowPlayingVM)
        case .playlistDetail(let playlist, let includesHidden):
            let detailView = PlaylistDetailView(
                playlist: playlist,
                nowPlayingVM: nowPlayingVM,
                includesHidden: includesHidden
            )
            .hiddenPlaybackScope(nowPlayingVM, isEnabled: includesHidden)
            #if os(iOS)
            if #available(iOS 18.0, *), let mediaNavigationNamespace {
                detailView.navigationTransition(
                    .zoom(sourceID: playlist.sourceScopedID, in: mediaNavigationNamespace)
                )
            } else {
                detailView
            }
            #else
            detailView
            #endif
        case .mergedPlaylist(let title, let isSmart):
            if let displayPlaylist = viewModels.playlists.displayPlaylists.first(where: {
                DisplayPlaylist.normalizedTitle($0.title) == DisplayPlaylist.normalizedTitle(title)
                    && $0.isSmart == isSmart
            }) {
                let detailView = MergedPlaylistDetailView(
                    displayPlaylist: displayPlaylist,
                    nowPlayingVM: nowPlayingVM
                )
                #if os(iOS)
                if #available(iOS 18.0, *), let mediaNavigationNamespace {
                    detailView.navigationTransition(
                        .zoom(
                            sourceID: displayPlaylist.primaryPlaylist.sourceScopedID,
                            in: mediaNavigationNamespace
                        )
                    )
                } else {
                    detailView
                }
                #else
                detailView
                #endif
            } else {
                MergedPlaylistDetailLoader(
                    title: title,
                    isSmart: isSmart,
                    nowPlayingVM: nowPlayingVM,
                    playlistsVM: viewModels.playlists
                )
            }
        case .moodTracks(let mood):
            MoodTracksView(mood: mood, nowPlayingVM: nowPlayingVM)
        case .hidden:
            HiddenMediaView(nowPlayingVM: nowPlayingVM, viewModel: viewModels.hidden)
        case .searchResults(let section):
            SearchView(
                nowPlayingVM: nowPlayingVM,
                viewModel: viewModels.search,
                pinnedVM: viewModels.pinned,
                resultSection: section
            )
        case .view(let tab):
            NavigationTabContentView(
                tab: tab,
                nowPlayingVM: nowPlayingVM,
                viewModels: viewModels,
                mediaNavigationNamespace: mediaNavigationNamespace,
                isMoreRoot: false,
                isSelectedRoot: true
            )
        }
    }

    @MainActor
    private static func displayGenre(for id: String, libraryVM: LibraryViewModel) -> DisplayGenre? {
        libraryVM.genreBrowse.snapshot.displayGenres.first { $0.id == id }
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
    let nowPlayingVM: NowPlayingViewModel
    let viewModels: RootScreenModels
    let mediaNavigationNamespace: Namespace.ID?
    let isMoreRoot: Bool
    let isSelectedRoot: Bool

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
            HomeView(nowPlayingVM: nowPlayingVM, viewModel: viewModels.home, isSelectedRoot: isSelectedRoot)
        case .songs:
            SongsView(libraryVM: viewModels.library, nowPlayingVM: nowPlayingVM)
        case .artists:
            ArtistsView(libraryVM: viewModels.library, nowPlayingVM: nowPlayingVM)
        case .albums:
            AlbumsView(libraryVM: viewModels.library, nowPlayingVM: nowPlayingVM)
        case .genres:
            GenresView(libraryVM: viewModels.library, nowPlayingVM: nowPlayingVM)
        case .playlists:
            PlaylistsView(nowPlayingVM: nowPlayingVM, viewModel: viewModels.playlists)
        case .favorites:
            FavoritesView(nowPlayingVM: nowPlayingVM, viewModel: viewModels.favorites)
        case .search:
            SearchView(nowPlayingVM: nowPlayingVM, viewModel: viewModels.search, pinnedVM: viewModels.pinned)
        case .downloads:
            DownloadsView(nowPlayingVM: nowPlayingVM, viewModel: viewModels.downloads)
        case .settings:
            ProfileView()
        }
    }
}
