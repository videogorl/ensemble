import EnsembleCore
import SwiftUI

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
                
                ZStack(alignment: .bottom) {
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
                    // Hide the standard tab bar since we're using a custom one for layering
                    .onAppear {
                        #if os(iOS)
                        let appearance = UITabBarAppearance()
                        appearance.configureWithTransparentBackground()
                        UITabBar.appearance().standardAppearance = appearance
                        UITabBar.appearance().scrollEdgeAppearance = appearance
                        #endif

                        // Sync visible tabs to NavigationCoordinator for fallback logic
                        navigationCoordinator.visibleTabs = barTabs
                    }
                    .onChange(of: settingsManager.enabledTabs) { _ in
                        // Keep visibleTabs in sync when user changes tab settings
                        navigationCoordinator.visibleTabs = barTabs
                    }

                    // Persistent UI Layer (MiniPlayer + Custom TabBar)
                    VStack(spacing: 0) {
                        MiniPlayer(viewModel: nowPlayingVM) {
                            showingNowPlaying = true
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))

                        customTabBar(safeAreaBottom: geometry.safeAreaInsets.bottom)
                            .background(
                                Rectangle()
                                    .fill(.regularMaterial)
                                    .shadow(color: .black.opacity(0.1), radius: 20, y: -5)
                            )
                    }
                    .zIndex(2)
                }
                .ignoresSafeArea(.container, edges: .bottom)
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
    }
    
    @ViewBuilder
    private func tabRootView(for tab: TabItem, isMoreRoot: Bool = false) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            NavigationStack(path: pathBinding(for: tab)) {
                viewForTab(tab, isMoreRoot: isMoreRoot)
                    .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                        destinationView(for: destination)
                    }
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: 110)
                    }
            }
        } else {
            NavigationView {
                viewForTab(tab, isMoreRoot: isMoreRoot)
                    // iOS 15 Fallback: Hidden NavigationLink driven by coordinator path
                    .background(
                        Group {
                            if let firstDest = pathForTab(tab).first {
                                NavigationLink(
                                    destination: destinationView(for: firstDest),
                                    isActive: Binding(
                                        get: { !pathForTab(tab).isEmpty },
                                        set: { if !$0 { navigationCoordinator.popToRoot(tab: tab) } }
                                    )
                                ) {
                                    EmptyView()
                                }
                            }
                        }
                    )
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: 110)
                    }
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
        }
    }
    
    private func customTabBar(safeAreaBottom: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(barTabs) { tab in
                tabItem(title: tab.rawValue, icon: tab.systemImage, tag: tab)
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
    
    @ViewBuilder
    private func viewForTab(_ tab: TabItem, isMoreRoot: Bool = false) -> some View {
        if isMoreRoot {
            MoreView(
                libraryVM: libraryVM,
                nowPlayingVM: nowPlayingVM,
                onSyncTap: {
                    showingSyncPanel = true
                }
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
                    HomeView(nowPlayingVM: nowPlayingVM)
                        .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                            destinationView(for: destination)
                        }
                }
            case .songs:
                NavigationStack {
                    SongsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
                }
            case .artists:
                NavigationStack(path: $navigationCoordinator.artistsPath) {
                    ArtistsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
                        .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                            destinationView(for: destination)
                        }
                }
            case .albums:
                NavigationStack(path: $navigationCoordinator.albumsPath) {
                    AlbumsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
                        .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                            destinationView(for: destination)
                        }
                }
            case .genres:
                NavigationStack {
                    GenresView(libraryVM: libraryVM)
                }
            case .playlists:
                NavigationStack(path: $navigationCoordinator.playlistsPath) {
                    PlaylistsView(nowPlayingVM: nowPlayingVM)
                        .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                            destinationView(for: destination)
                        }
                }
            case .favorites:
                NavigationStack {
                    FavoritesView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
                }
            case .search:
                NavigationStack(path: $navigationCoordinator.searchPath) {
                    SearchView(nowPlayingVM: nowPlayingVM, viewModel: searchVM)
                        .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                            destinationView(for: destination)
                        }
                }
            case .downloads:
                NavigationStack {
                    DownloadsView(nowPlayingVM: nowPlayingVM)
                }
            case .settings:
                NavigationStack {
                    SettingsView()
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
