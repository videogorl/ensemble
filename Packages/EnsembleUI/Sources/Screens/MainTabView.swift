import EnsembleCore
import SwiftUI

// MARK: - Tab View Factory

struct TabViewFactory {
    @ViewBuilder
    static func view(
        for tab: TabItem,
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        searchVM: SearchViewModel,
        onSyncTap: @escaping () -> Void,
        isMoreRoot: Bool = false
    ) -> some View {
        if isMoreRoot {
            MoreView(
                libraryVM: libraryVM,
                nowPlayingVM: nowPlayingVM,
                onSyncTap: onSyncTap
            )
        } else {
            switch tab {
            case .home:
                HomeView(nowPlayingVM: nowPlayingVM)
            case .songs:
                SongsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
            case .artists:
                ArtistsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
            case .albums:
                AlbumsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
            case .genres:
                GenresView(libraryVM: libraryVM)
            case .playlists:
                PlaylistsView(nowPlayingVM: nowPlayingVM)
            case .favorites:
                FavoritesView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
            case .search:
                SearchView(nowPlayingVM: nowPlayingVM, viewModel: searchVM)
            case .downloads:
                DownloadsView(nowPlayingVM: nowPlayingVM)
            case .settings:
                SettingsView()
            }
        }
    }
}

/// Main tab bar view for iPhone (5-tab classic iOS style)
public struct MainTabView: View {
    @StateObject private var libraryVM: LibraryViewModel
    @StateObject private var nowPlayingVM: NowPlayingViewModel
    @StateObject private var searchVM: SearchViewModel
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @ObservedObject private var networkMonitor = DependencyContainer.shared.networkMonitor
    @ObservedObject private var navigationCoordinator = DependencyContainer.shared.navigationCoordinator
    @Environment(\.dependencies) private var deps
    
    #if os(iOS)
    @StateObject private var keyboard = KeyboardObserver()
    #endif

    @State private var showingNowPlaying = false
    @State private var showingSyncPanel = false
    @State private var didSetInitialTab = false
    @State private var isImmersiveMode = false
    
    // Get the tabs to show in the bar (limit to 4, then More)
    private var barTabs: [TabItem] {
        Array(settingsManager.enabledTabs.prefix(4))
    }

    public init() {
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self._nowPlayingVM = StateObject(wrappedValue: DependencyContainer.shared.makeNowPlayingViewModel())
        self._searchVM = StateObject(wrappedValue: DependencyContainer.shared.makeSearchViewModel())
    }

    private var isKeyboardVisible: Bool {
        #if os(iOS)
        return keyboard.isVisible
        #else
        return false
        #endif
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Connection status banner at top
                if !isImmersiveMode {
                    ConnectionStatusBanner(networkState: networkMonitor.networkState)
                }
                
                // Main content layer (TabView)
                tabBarVisibility(
                    TabView(selection: tabBinding) {
                    // Dynamic Tabs
                    ForEach(barTabs) { tab in
                        tabRootView(for: tab)
                            .tag(tab)
                            .tabItem {
                                Label(tab.displayTitle, systemImage: tab.systemImage)
                            }
                    }

                    // Always show More as the 5th tab
                    tabRootView(for: .settings, isMoreRoot: true)
                        .tag(TabItem.settings)
                        .tabItem {
                            Label("More", systemImage: "ellipsis")
                        }
                },
                    isHidden: isImmersiveMode
                )
                // Use the new native floating style if available (iOS 18+)
                .tabViewStyle(sidebarAdaptableIfAvailable())
                .onAppear {
                    // Sync visible tabs to NavigationCoordinator for fallback logic
                    navigationCoordinator.visibleTabs = barTabs

                    if !didSetInitialTab {
                        navigationCoordinator.selectedTab = barTabs.first ?? .home
                        didSetInitialTab = true
                    }
                }
                .onChange(of: settingsManager.enabledTabs) { _ in
                    // Keep visibleTabs in sync when user changes tab settings
                    navigationCoordinator.visibleTabs = barTabs
                }
            }

            // Persistent MiniPlayer (Floating above native TabBar)
            if !isKeyboardVisible && !isImmersiveMode {
                MiniPlayer(viewModel: nowPlayingVM) {
                    showingNowPlaying = true
                }
                .padding(.bottom, 56) // Offset to sit above native TabBar on iPhone
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingView(viewModel: nowPlayingVM)
        }
        .sheet(isPresented: $showingSyncPanel) {
            SyncPanelView()
        }
        .task {
            await libraryVM.refresh()
        }
        .onChange(of: showingNowPlaying) { isShowing in
            // Handle pending navigation when NowPlaying dismisses
            if !isShowing, let pending = navigationCoordinator.pendingNavigation {
                // The coordinator already determined the correct tab (current or fallback)
                navigationCoordinator.selectedTab = pending.tab
                
                // Push onto the target tab stack
                navigationCoordinator.push(pending.destination, in: pending.tab)
                navigationCoordinator.pendingNavigation = nil
            }
        }
        .onPreferenceChange(ChromeVisibilityPreferenceKey.self) { isHidden in
            if isImmersiveMode != isHidden {
                isImmersiveMode = isHidden
                #if os(iOS)
                UITabBar.appearance().isHidden = isHidden
                #endif
            }
        }
    }

    @ViewBuilder
    private func tabBarVisibility<Content: View>(_ content: Content, isHidden: Bool) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            content.toolbar(isHidden ? .hidden : .visible, for: .tabBar)
        } else {
            content
        }
        #else
        content
        #endif
    }
    
    private func sidebarAdaptableIfAvailable() -> some TabViewStyle {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            return .sidebarAdaptable
        }
        #endif
        return .automatic
    }
    
    private var tabBinding: Binding<TabItem> {
        Binding(
            get: { navigationCoordinator.selectedTab },
            set: { handleTabTap($0) }
        )
    }
    
    private func handleTabTap(_ tag: TabItem) {
        if navigationCoordinator.selectedTab == tag {
            // Already on this tab
            if !pathForTab(tag).isEmpty {
                navigationCoordinator.popToRoot(tab: tag)
            } else if tag == .search {
                searchVM.requestFocus()
            }
        } else {
            navigationCoordinator.selectedTab = tag
        }
        
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
    
    @ViewBuilder
    private func tabRootView(for tab: TabItem, isMoreRoot: Bool = false) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            NavigationStack(path: pathBinding(for: tab)) {
                TabViewFactory.view(
                    for: tab,
                    libraryVM: libraryVM,
                    nowPlayingVM: nowPlayingVM,
                    searchVM: searchVM,
                    onSyncTap: { showingSyncPanel = true },
                    isMoreRoot: isMoreRoot
                )
                .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                    destinationView(for: destination)
                }
            }
        } else {
            NavigationView {
                // iOS 15 Fallback: Support nested navigation by passing the remaining path
                TabViewFactory.view(
                    for: tab,
                    libraryVM: libraryVM,
                    nowPlayingVM: nowPlayingVM,
                    searchVM: searchVM,
                    onSyncTap: { showingSyncPanel = true },
                    isMoreRoot: isMoreRoot
                )
                .background(
                    NestedNavigationLink(
                        path: pathForTab(tab),
                        tab: tab,
                        destinationBuilder: destinationView
                    )
                )
            }
            #if os(iOS)
            .navigationViewStyle(.stack)
            #endif
        }
    }

    private func pathBinding(for tab: TabItem) -> Binding<[NavigationCoordinator.Destination]> {
        switch tab {
        case .home: return $navigationCoordinator.homePath
        case .artists: return $navigationCoordinator.artistsPath
        case .albums: return $navigationCoordinator.albumsPath
        case .playlists: return $navigationCoordinator.playlistsPath
        case .search: return $navigationCoordinator.searchPath
        case .settings: return $navigationCoordinator.settingsPath
        default: return .constant([])
        }
    }

    private func pathForTab(_ tab: TabItem) -> [NavigationCoordinator.Destination] {
        switch tab {
        case .home: return navigationCoordinator.homePath
        case .artists: return navigationCoordinator.artistsPath
        case .albums: return navigationCoordinator.albumsPath
        case .playlists: return navigationCoordinator.playlistsPath
        case .search: return navigationCoordinator.searchPath
        case .settings: return navigationCoordinator.settingsPath
        default: return []
        }
    }

    @ViewBuilder
    private func destinationView(for destination: NavigationCoordinator.Destination) -> some View {
        switch destination {
        case .artist(let id):
            ArtistDetailLoader(artistId: id, nowPlayingVM: nowPlayingVM)
        case .album(let id):
            AlbumDetailLoader(albumId: id, nowPlayingVM: nowPlayingVM)
        case .playlist(let id):
            PlaylistDetailLoader(playlistId: id, nowPlayingVM: nowPlayingVM)
        case .moodTracks(let mood):
            MoodTracksView(mood: mood, nowPlayingVM: nowPlayingVM)
        case .view(let tab):
            TabViewFactory.view(
                for: tab,
                libraryVM: libraryVM,
                nowPlayingVM: nowPlayingVM,
                searchVM: searchVM,
                onSyncTap: { showingSyncPanel = true }
            )
        }
    }
}

// MARK: - iOS 15 Navigation Helpers

struct NestedNavigationLink<DestinationView: View>: View {
    let path: [NavigationCoordinator.Destination]
    let tab: TabItem
    let destinationBuilder: (NavigationCoordinator.Destination) -> DestinationView
    
    var body: some View {
        if let first = path.first {
            NavigationLink(
                isActive: Binding(
                    get: { !path.isEmpty },
                    set: { if !$0 { DependencyContainer.shared.navigationCoordinator.popToRoot(tab: tab) } }
                ),
                destination: {
                    destinationBuilder(first)
                        .background(
                            NestedNavigationLink(
                                path: Array(path.dropFirst()),
                                tab: tab,
                                destinationBuilder: destinationBuilder
                            )
                        )
                }
            ) {
                EmptyView()
            }
        }
    }
}

// MARK: - iPad Sidebar View

@available(iOS 16.0, macOS 13.0, *)
public struct SidebarView: View {
    @StateObject private var libraryVM: LibraryViewModel
    @StateObject private var nowPlayingVM: NowPlayingViewModel
    @StateObject private var searchVM: SearchViewModel
    @StateObject private var pinnedVM: PinnedViewModel
    @ObservedObject private var navigationCoordinator = DependencyContainer.shared.navigationCoordinator
    @Environment(\.dependencies) private var deps

    @State private var selection: SidebarSection? = .home
    @State private var showingNowPlaying = false
    @State private var showingSyncPanel = false

    public init() {
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self._nowPlayingVM = StateObject(wrappedValue: DependencyContainer.shared.makeNowPlayingViewModel())
        self._searchVM = StateObject(wrappedValue: DependencyContainer.shared.makeSearchViewModel())
        self._pinnedVM = StateObject(wrappedValue: DependencyContainer.shared.makePinnedViewModel())
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            // Main split view
            NavigationSplitView {
                List(selection: $selection) {
                    Section(header: Text("Library").textCase(nil)) {
                        Label("Home", systemImage: "house")
                            .tag(SidebarSection.home)

                        Label("Songs", systemImage: "music.note")
                            .tag(SidebarSection.songs)

                        Label("Artists", systemImage: "music.mic")
                            .tag(SidebarSection.artists)

                        Label("Albums", systemImage: "square.stack")
                            .tag(SidebarSection.albums)

                        Label("Genres", systemImage: "guitars")
                            .tag(SidebarSection.genres)

                        Label("Playlists", systemImage: "music.note.list")
                            .tag(SidebarSection.playlists)

                        Label("Favorites", systemImage: "heart.fill")
                            .tag(SidebarSection.favorites)
                    }

                    // Pinned items section (hidden when empty)
                    if !pinnedVM.resolvedPins.isEmpty {
                        Section(header: Text("Pins").textCase(nil)) {
                            ForEach(pinnedVM.resolvedPins) { pin in
                                Label(pin.pinnedItem.title, systemImage: iconForPinType(pin.pinnedItem.type))
                                    .tag(SidebarSection.pin(id: pin.pinnedItem.id, type: pin.pinnedItem.type))
                            }
                            .onMove { source, destination in
                                pinnedVM.move(fromOffsets: source, toOffset: destination)
                            }
                        }
                    }

                    Section(header: Text("Other").textCase(nil)) {
                        Label("Search", systemImage: "magnifyingglass")
                            .tag(SidebarSection.search)

                        Label("Downloads", systemImage: "arrow.down.circle")
                            .tag(SidebarSection.downloads)

                        Label("Settings", systemImage: "gear")
                            .tag(SidebarSection.settings)
                        
                        Button {
                            showingSyncPanel = true
                        } label: {
                            Label("Library Sync", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }
                .listStyle(.sidebar)
                .navigationTitle("Ensemble")
            } detail: {
                detailView
            }

            // Mini player overlay (always on top)
            MiniPlayer(viewModel: nowPlayingVM) {
                showingNowPlaying = true
            }
            .zIndex(2)
        }
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingView(viewModel: nowPlayingVM)
        }
        .sheet(isPresented: $showingSyncPanel) {
            SyncPanelView()
        }
        .task {
            await libraryVM.refresh()
            await pinnedVM.loadPinnedItems()
        }
    }

    /// SF Symbol for each pinned item type
    private func iconForPinType(_ type: PinnedItemType) -> String {
        switch type {
        case .album: return "square.stack"
        case .artist: return "music.mic"
        case .playlist: return "music.note.list"
        }
    }
    
    @ViewBuilder
    private var detailView: some View {
        Group {
            switch selection {
            case .home:
                NavigationStack(path: $navigationCoordinator.homePath) {
                    TabViewFactory.view(for: .home, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM, onSyncTap: { showingSyncPanel = true })
                        .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                            destinationView(for: destination)
                        }
                }
            case .songs:
                NavigationStack {
                    TabViewFactory.view(for: .songs, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM, onSyncTap: { showingSyncPanel = true })
                }
            case .artists:
                NavigationStack(path: $navigationCoordinator.artistsPath) {
                    TabViewFactory.view(for: .artists, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM, onSyncTap: { showingSyncPanel = true })
                        .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                            destinationView(for: destination)
                        }
                }
            case .albums:
                NavigationStack(path: $navigationCoordinator.albumsPath) {
                    TabViewFactory.view(for: .albums, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM, onSyncTap: { showingSyncPanel = true })
                        .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                            destinationView(for: destination)
                        }
                }
            case .genres:
                NavigationStack {
                    TabViewFactory.view(for: .genres, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM, onSyncTap: { showingSyncPanel = true })
                }
            case .playlists:
                NavigationStack(path: $navigationCoordinator.playlistsPath) {
                    TabViewFactory.view(for: .playlists, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM, onSyncTap: { showingSyncPanel = true })
                        .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                            destinationView(for: destination)
                        }
                }
            case .favorites:
                NavigationStack {
                    TabViewFactory.view(for: .favorites, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM, onSyncTap: { showingSyncPanel = true })
                }
            case .search:
                NavigationStack(path: $navigationCoordinator.searchPath) {
                    TabViewFactory.view(for: .search, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM, onSyncTap: { showingSyncPanel = true })
                        .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                            destinationView(for: destination)
                        }
                }
            case .downloads:
                NavigationStack {
                    TabViewFactory.view(for: .downloads, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM, onSyncTap: { showingSyncPanel = true })
                }
            case .settings:
                NavigationStack {
                    TabViewFactory.view(for: .settings, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM, onSyncTap: { showingSyncPanel = true })
                }
            case .pin(let id, let type):
                // Navigate directly to the pinned item's detail view
                NavigationStack {
                    switch type {
                    case .album:
                        AlbumDetailLoader(albumId: id, nowPlayingVM: nowPlayingVM)
                    case .artist:
                        ArtistDetailLoader(artistId: id, nowPlayingVM: nowPlayingVM)
                    case .playlist:
                        PlaylistDetailLoader(playlistId: id, nowPlayingVM: nowPlayingVM)
                    }
                }
            case .none:
                Text("Select a section")
                    .foregroundColor(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 64)
        }
    }
    
    @ViewBuilder
    private func destinationView(for destination: NavigationCoordinator.Destination) -> some View {
        switch destination {
        case .artist(let id):
            ArtistDetailLoader(artistId: id, nowPlayingVM: nowPlayingVM)
        case .album(let id):
            AlbumDetailLoader(albumId: id, nowPlayingVM: nowPlayingVM)
        case .playlist(let id):
            PlaylistDetailLoader(playlistId: id, nowPlayingVM: nowPlayingVM)
        case .moodTracks(let mood):
            MoodTracksView(mood: mood, nowPlayingVM: nowPlayingVM)
        case .view(let tab):
            TabViewFactory.view(
                for: tab,
                libraryVM: libraryVM,
                nowPlayingVM: nowPlayingVM,
                searchVM: searchVM,
                onSyncTap: { showingSyncPanel = true }
            )
        }
    }
}

public enum SidebarSection: Hashable {
    case home
    case songs
    case artists
    case albums
    case genres
    case playlists
    case favorites
    case search
    case downloads
    case settings
    case pin(id: String, type: PinnedItemType)
}
