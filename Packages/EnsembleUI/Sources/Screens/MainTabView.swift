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

    @State private var showingNowPlaying = false
    @State private var showingSyncPanel = false
    @State private var didSetInitialTab = false
    @State private var baseSafeAreaBottom: CGFloat = 0
    
    // Get the tabs to show in the bar (limit to 4, then More)
    private var barTabs: [TabItem] {
        Array(settingsManager.enabledTabs.prefix(4))
    }

    public init() {
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self._nowPlayingVM = StateObject(wrappedValue: DependencyContainer.shared.makeNowPlayingViewModel())
        self._searchVM = StateObject(wrappedValue: DependencyContainer.shared.makeSearchViewModel())
    }

    public var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Connection status banner at top
                ConnectionStatusBanner(networkState: networkMonitor.networkState)
                
                // Main content layer (TabView)
                TabView(selection: $navigationCoordinator.selectedTab) {
                    // Dynamic Tabs
                    ForEach(barTabs) { tab in
                        tabRootView(for: tab)
                            .tag(tab)
                    }

                    // Always show More as the 5th tab
                    tabRootView(for: .settings, isMoreRoot: true)
                        .tag(TabItem.settings)
                }
                // Hide the standard tab bar since we're using a custom one
                .onAppear {
                    #if os(iOS)
                    UITabBar.appearance().isHidden = true
                    #endif

                    // Sync visible tabs to NavigationCoordinator for fallback logic
                    navigationCoordinator.visibleTabs = barTabs

                    if baseSafeAreaBottom == 0 {
                        baseSafeAreaBottom = geometry.safeAreaInsets.bottom
                    }

                    if !didSetInitialTab {
                        navigationCoordinator.selectedTab = barTabs.first ?? .home
                        didSetInitialTab = true
                    }
                }
                #if os(iOS)
                .toolbar(.hidden, for: .tabBar)
                #endif
                .onChange(of: settingsManager.enabledTabs) { _ in
                    // Keep visibleTabs in sync when user changes tab settings
                    navigationCoordinator.visibleTabs = barTabs
                }
                .padding(.bottom, 110)
                .overlay(alignment: .bottom) {
                    // Persistent UI Layer (MiniPlayer + Custom TabBar)
                    VStack(spacing: 0) {
                        MiniPlayer(viewModel: nowPlayingVM) {
                            showingNowPlaying = true
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))

                        customTabBar(safeAreaBottom: baseSafeAreaBottom)
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
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
    private func tabContainer(geometry: GeometryProxy) -> some View {
        if #available(iOS 16.0, *) {
            baseTabView(geometry: geometry)
                .toolbar(.hidden, for: .tabBar)
        } else {
            baseTabView(geometry: geometry)
        }
    }

    private func baseTabView(geometry: GeometryProxy) -> some View {
        TabView(selection: $navigationCoordinator.selectedTab) {
            // Dynamic Tabs
            ForEach(barTabs) { tab in
                tabRootView(for: tab)
                    .tag(tab)
            }

            // Always show More as the 5th tab
            tabRootView(for: .settings, isMoreRoot: true)
                .tag(TabItem.settings)
        }
        // Hide the standard tab bar since we're using a custom one
        .onAppear {
            #if os(iOS)
            UITabBar.appearance().isHidden = true
            #endif

            // Sync visible tabs to NavigationCoordinator for fallback logic
            navigationCoordinator.visibleTabs = barTabs

            if baseSafeAreaBottom == 0 {
                baseSafeAreaBottom = geometry.safeAreaInsets.bottom
            }

            if !didSetInitialTab {
                navigationCoordinator.selectedTab = barTabs.first ?? .home
                didSetInitialTab = true
            }
        }
        .onChange(of: settingsManager.enabledTabs) { _ in
            // Keep visibleTabs in sync when user changes tab settings
            navigationCoordinator.visibleTabs = barTabs
        }
        .padding(.bottom, 110)
        .overlay(alignment: .bottom) {
            // Persistent UI Layer (MiniPlayer + Custom TabBar)
            VStack(spacing: 0) {
                MiniPlayer(viewModel: nowPlayingVM) {
                    showingNowPlaying = true
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))

                customTabBar(safeAreaBottom: baseSafeAreaBottom)
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .ignoresSafeArea(.keyboard, edges: .bottom)
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
    
    private func customTabBar(safeAreaBottom: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(barTabs) { tab in
                tabItem(title: tab.displayTitle, icon: tab.systemImage, tag: tab)
            }
            
            tabItem(title: "More", icon: "ellipsis", tag: .settings)
        }
        .padding(.horizontal, 4)
        .frame(height: 49)
        .padding(.bottom, safeAreaBottom > 0 ? safeAreaBottom : 8)
    }
    
    private func tabItem(title: String, icon: String, tag: TabItem) -> some View {
        let isSelected = navigationCoordinator.selectedTab == tag
        
        return VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 23))
                .frame(height: 26)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .foregroundColor(isSelected ? .accentColor : .secondary)
        .onTapGesture {
            handleTabTap(tag)
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            if tag == .search {
                handleTabTap(.search)
                searchVM.requestFocus()
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
            }
        }
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
    @ObservedObject private var navigationCoordinator = DependencyContainer.shared.navigationCoordinator
    @Environment(\.dependencies) private var deps

    @State private var selection: SidebarSection? = .home
    @State private var showingNowPlaying = false
    @State private var showingSyncPanel = false

    public init() {
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self._nowPlayingVM = StateObject(wrappedValue: DependencyContainer.shared.makeNowPlayingViewModel())
        self._searchVM = StateObject(wrappedValue: DependencyContainer.shared.makeSearchViewModel())
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            // Main split view
            NavigationSplitView {
                List(selection: $selection) {
                    Section("Library") {
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

                    Section("Other") {
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
}
