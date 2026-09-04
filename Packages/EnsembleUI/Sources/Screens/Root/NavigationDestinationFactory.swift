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
            if let displayArtist = displayArtist(for: id, libraryVM: libraryVM) {
                ArtistDetailView(displayArtist: displayArtist, nowPlayingVM: nowPlayingVM)
            } else {
                EnsembleStateScaffold(kind: .empty, title: "Artist not found")
            }
        case .artistNamed(let name, let fallbackID, let sourceKey, let includesHidden):
            if let displayArtist = displayArtist(named: name, libraryVM: libraryVM) {
                ArtistDetailView(
                    displayArtist: displayArtist,
                    nowPlayingVM: nowPlayingVM,
                    includesHidden: includesHidden
                )
                .hiddenPlaybackScope(nowPlayingVM, isEnabled: includesHidden)
            } else if let fallbackID {
                ArtistDetailLoader(
                    artistId: fallbackID,
                    artistSourceKey: sourceKey,
                    nowPlayingVM: nowPlayingVM,
                    includesHidden: includesHidden
                )
                .hiddenPlaybackScope(nowPlayingVM, isEnabled: includesHidden)
            } else {
                EnsembleStateScaffold(kind: .empty, title: "Artist not found")
            }
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
            let detailView = ArtistDetailView(
                artist: artist,
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
            ArtistDetailLoader(artistId: id, artistSourceKey: sourceKey, nowPlayingVM: nowPlayingVM)
        case .album(let id, let sourceKey):
            AlbumDetailLoader(albumId: id, albumSourceKey: sourceKey, nowPlayingVM: nowPlayingVM)
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
    private static func displayArtist(for id: String, libraryVM: LibraryViewModel) -> DisplayArtist? {
        if let displayArtist = libraryVM.artistBrowseSnapshot.displayArtists.first(where: { $0.id == id }) {
            return displayArtist
        }

        return DisplayArtist.group(
            libraryVM.artists,
            preferences: SettingsManager.storedMergingPreferences()
        ).first { $0.id == id }
    }

    @MainActor
    private static func displayArtist(named name: String, libraryVM: LibraryViewModel) -> DisplayArtist? {
        let normalizedName = DisplayArtist.normalizedName(name)
        return libraryVM.artistBrowseSnapshot.displayArtists.first {
            DisplayArtist.normalizedName($0.name) == normalizedName
        } ?? DisplayArtist.group(
            libraryVM.artists,
            preferences: SettingsManager.storedMergingPreferences()
        ).first {
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
