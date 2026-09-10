#if DEBUG && (os(iOS) || os(macOS))
import EnsembleCore
import SwiftUI

/// Throwaway native-container experiment; enabled only by a Debug launch argument.
@available(iOS 18.0, macOS 15.0, *)
struct NativeBrowsePrototype: View {
    let nowPlayingVM: NowPlayingViewModel
    let viewModels: RootScreenModels
    @Binding var selection: SidebarSelection?
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @ObservedObject private var pins: PinnedViewModel
    @State private var samplePins: [ResolvedPin] = []

    init(nowPlayingVM: NowPlayingViewModel, viewModels: RootScreenModels, selection: Binding<SidebarSelection?>) {
        self.nowPlayingVM = nowPlayingVM
        self.viewModels = viewModels
        _selection = selection
        _pins = ObservedObject(wrappedValue: viewModels.pinned)
    }

    var body: some View {
        TabView(selection: Binding(
            get: { selection ?? .library(.home) },
            set: { newSelection in
                if selection?.isPinnedDetailSelection == true, let tab = selection?.correspondingTab {
                    navigationCoordinator.setPath([], for: tab)
                }
                selection = newSelection
                if let tab = newSelection.correspondingTab {
                    if newSelection.isPinnedDetailSelection {
                        navigationCoordinator.setPath([], for: tab)
                    }
                    navigationCoordinator.selectedTab = tab
                }
            }
        )) {
            // ponytail: fixed tabs test container composition; reuse user tab preferences before shipping.
            ForEach([TabItem.home, .artists, .albums, .songs, .genres, .playlists, .search]) { tab in
                Tab(tab.displayTitle, systemImage: tab.systemImage, value: SidebarSelection.library(tab)) {
                    NativeBrowsePrototypeSection(tab: tab, nowPlayingVM: nowPlayingVM, viewModels: viewModels)
                }
            }
            TabSection("Pins") {
                ForEach(pins.resolvedPins + samplePins) { pin in
                    let item = pin.pinnedItem
                    Tab(item.title, systemImage: "pin", value: SidebarSelection.pin(
                        id: item.id, sourceKey: item.sourceCompositeKey, type: item.type
                    )) {
                        NavigationStack(path: navigationCoordinator.pathBinding(for: pinTab(pin))) {
                            pinContent(pin)
                                .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                                    NavigationDestinationFactory.destinationContent(
                                        for: destination, nowPlayingVM: nowPlayingVM, viewModels: viewModels
                                    )
                                }
                        }
                    }
                    .defaultVisibility(.hidden, for: .tabBar)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .task {
            async let library: () = viewModels.library.loadLibraryIfNeeded()
            async let pinned: () = pins.loadPinnedItemsIfNeeded()
            async let playlists: () = viewModels.playlists.loadPlaylistsIfNeeded()
            _ = await (library, pinned, playlists)
            // An in-memory pin exercises routing without changing or syncing user preferences.
            if ProcessInfo.processInfo.arguments.contains("-EnsembleNativeBrowseSamplePin"),
               pins.resolvedPins.isEmpty,
               let artist = viewModels.library.artistBrowseSnapshot.displayArtists.first(where: { $0.name == "AJR" }) {
                let item = PinnedItem(id: artist.primaryArtist.id,
                                      sourceCompositeKey: artist.primaryArtist.sourceCompositeKey ?? "",
                                      type: .artist, title: "Test Pin: AJR")
                samplePins = [.mergedArtist(artist, [item])]
            }
        }
    }

    private func pinTab(_ pin: ResolvedPin) -> TabItem {
        switch pin.pinnedItem.type {
        case .artist: return .artists
        case .album: return .albums
        case .playlist: return .playlists
        }
    }

    @ViewBuilder
    private func pinContent(_ pin: ResolvedPin) -> some View {
        switch pin {
        case .album(let album, _): AlbumDetailView(album: album, nowPlayingVM: nowPlayingVM)
        case .mergedAlbum(let album, _): AlbumDetailView(displayAlbum: album, nowPlayingVM: nowPlayingVM)
        case .artist(let artist, _): ArtistDetailView(artist: artist, nowPlayingVM: nowPlayingVM)
        case .mergedArtist(let artist, _): ArtistDetailView(displayArtist: artist, nowPlayingVM: nowPlayingVM)
        case .playlist(let playlist, _): PlaylistDetailView(playlist: playlist, nowPlayingVM: nowPlayingVM)
        case .mergedPlaylist(let playlist, _): MergedPlaylistDetailView(displayPlaylist: playlist, nowPlayingVM: nowPlayingVM)
        }
    }
}

@available(iOS 18.0, macOS 15.0, *)
private struct NativeBrowsePrototypeSection: View {
    let tab: TabItem
    let nowPlayingVM: NowPlayingViewModel
    let viewModels: RootScreenModels
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var artist: DisplayArtist?
    @State private var genre: DisplayGenre?
    @State private var playlist: DisplayPlaylist?
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar

    var body: some View {
        if [.artists, .genres, .playlists].contains(tab) {
            NavigationSplitView(preferredCompactColumn: $compactColumn) {
                selectionColumn
                    .navigationSplitViewColumnWidth(300)
            } detail: {
                detailStack
            }
            .navigationSplitViewStyle(.balanced)
            .onChange(of: selectedID) { _, newValue in
                navigationCoordinator.setPath([], for: tab)
                compactColumn = newValue == nil ? .sidebar : .detail
            }
        } else {
            detailStack
        }
    }

    private var selectedID: String? {
        artist?.id ?? genre?.id ?? playlist?.id
    }

    @ViewBuilder
    private var selectionColumn: some View {
        switch tab {
        case .artists:
            ArtistsView(libraryVM: viewModels.library, nowPlayingVM: nowPlayingVM,
                        presentationMode: .selectionColumn, selectedArtist: $artist)
        case .genres:
            GenresView(libraryVM: viewModels.library, nowPlayingVM: nowPlayingVM,
                       presentationMode: .selectionColumn, selectedGenre: $genre)
        case .playlists:
            PlaylistsView(nowPlayingVM: nowPlayingVM, viewModel: viewModels.playlists,
                          presentationMode: .selectionColumn, selectedPlaylist: $playlist)
        default: EmptyView()
        }
    }

    private var detailStack: some View {
        NavigationStack(path: navigationCoordinator.pathBinding(for: tab)) {
            detailRoot
                .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                    NavigationDestinationFactory.destinationContent(
                        for: destination, nowPlayingVM: nowPlayingVM, viewModels: viewModels
                    )
                }
        }
    }

    @ViewBuilder
    private var detailRoot: some View {
        switch tab {
        case .artists:
            if let artist {
                ArtistDetailView(displayArtist: artist, nowPlayingVM: nowPlayingVM).id(artist.id)
            } else {
                LargeScreenPlaceholderView(systemImage: tab.systemImage, title: "Select an Artist")
            }
        case .genres:
            if let genre {
                GenreDetailContentView(libraryVM: viewModels.library, genre: genre,
                                       nowPlayingVM: nowPlayingVM, presentationStyle: .splitPane).id(genre.id)
            } else {
                LargeScreenPlaceholderView(systemImage: tab.systemImage, title: "Select a Genre")
            }
        case .playlists:
            if let playlist {
                if playlist.isMerged {
                    MergedPlaylistDetailView(displayPlaylist: playlist, nowPlayingVM: nowPlayingVM).id(playlist.id)
                } else {
                    PlaylistDetailView(playlist: playlist.primaryPlaylist, nowPlayingVM: nowPlayingVM).id(playlist.id)
                }
            } else {
                LargeScreenPlaceholderView(systemImage: tab.systemImage, title: "Select a Playlist")
            }
        default:
            NavigationDestinationFactory.tabContent(for: tab, nowPlayingVM: nowPlayingVM, viewModels: viewModels)
        }
    }
}
#endif
