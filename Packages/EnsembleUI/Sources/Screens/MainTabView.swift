import EnsembleCore
import SwiftUI

/// Main tab bar view for iPhone (5-tab classic iOS style)
public struct MainTabView: View {
    @StateObject private var libraryVM: LibraryViewModel
    @StateObject private var nowPlayingVM: NowPlayingViewModel
    @StateObject private var searchVM: SearchViewModel
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @Environment(\.dependencies) private var deps

    @State private var selectedTab: TabItem = .home
    @State private var showingNowPlaying = false
    @State private var showingSyncPanel = false
    @State private var showingDetailView = false
    
    // IDs to trigger pop-to-root by resetting NavigationViews
    @State private var tabRootIDs: [TabItem: Int] = [:]
    
    // Get the tabs to show in the bar (limit to 4, then More)
    private var barTabs: [TabItem] {
        Array(settingsManager.enabledTabs.prefix(4))
    }

    // Helper to dismiss the detail view overlay
    private func dismissDetailView() {
        withAnimation(.easeInOut(duration: 0.3)) {
            showingDetailView = false
        }
        // Clear destination after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            deps.navigationCoordinator.clearDestination()
        }
    }

    public init() {
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self._nowPlayingVM = StateObject(wrappedValue: DependencyContainer.shared.makeNowPlayingViewModel())
        self._searchVM = StateObject(wrappedValue: DependencyContainer.shared.makeSearchViewModel())
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Main content layer (TabView)
                TabView(selection: $selectedTab) {
                    // Dynamic Tabs
                    ForEach(barTabs) { tab in
                        NavigationView {
                            viewForTab(tab)
                        }
                        .id(tabRootIDs[tab, default: 0])
                        #if os(iOS)
                        .navigationViewStyle(.stack)
                        #endif
                        .safeAreaInset(edge: .bottom) {
                            Color.clear.frame(height: 110)
                        }
                        .tag(tab)
                    }

                    // Always show More
                    NavigationView {
                        MoreView(
                            libraryVM: libraryVM,
                            nowPlayingVM: nowPlayingVM,
                            onSyncTap: {
                                showingSyncPanel = true
                            }
                        )
                    }
                    .id(tabRootIDs[.settings, default: 0])
                    #if os(iOS)
                    .navigationViewStyle(.stack)
                    #endif
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: 110)
                    }
                    .tag(TabItem.settings) // Using settings as a proxy tag for More
                }
                // Hide the standard tab bar since we're using a custom one for layering
                .onAppear {
                    #if os(iOS)
                    let appearance = UITabBarAppearance()
                    appearance.configureWithTransparentBackground()
                    UITabBar.appearance().standardAppearance = appearance
                    UITabBar.appearance().scrollEdgeAppearance = appearance
                    #endif
                    
                    // Set initial tab if home isn't enabled
                    if !barTabs.contains(.home) {
                        selectedTab = barTabs.first ?? .settings
                    }
                }

                // Sliding detail view overlay
                if showingDetailView, let destination = deps.navigationCoordinator.pendingDestination {
                    detailViewForDestination(destination: destination)
                        .transition(.move(edge: .trailing))
                        .zIndex(1)
                }

                // Persistent UI Layer (MiniPlayer + Custom TabBar)
                VStack(spacing: 0) {
                    MiniPlayer(viewModel: nowPlayingVM) {
                        showingNowPlaying = true
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                    customTabBar(safeAreaBottom: geometry.safeAreaInsets.bottom)
                }
                .background(.ultraThinMaterial)
                .zIndex(2)
            }
            .ignoresSafeArea(.container, edges: .bottom)
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
        .onChange(of: deps.navigationCoordinator.pendingDestination) { destination in
            // Show detail view when navigation is requested
            withAnimation(.easeInOut(duration: 0.3)) {
                showingDetailView = destination != nil
            }
        }
        .onChange(of: selectedTab) { _ in
            // Dismiss detail view when switching tabs
            if showingDetailView {
                dismissDetailView()
            }
        }
        .onChange(of: showingSyncPanel) { isShowing in
            // Dismiss detail view when opening sync panel
            if isShowing && showingDetailView {
                dismissDetailView()
            }
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
        let isSelected = selectedTab == tag
        
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
        if selectedTab == tag {
            // Already on this tab
            if showingDetailView {
                dismissDetailView()
            } else if tag == .search {
                searchVM.requestFocus()
            } else {
                // Pop to root by incrementing ID
                tabRootIDs[tag, default: 0] += 1
            }
        } else {
            selectedTab = tag
        }
        
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
    
    @ViewBuilder
    private func viewForTab(_ tab: TabItem) -> some View {
        switch tab {
        case .home:
            HomeView(
                nowPlayingVM: nowPlayingVM,
                onAlbumTap: { album in
                    deps.navigationCoordinator.navigateToAlbum(album)
                },
                onArtistTap: { artist in
                    deps.navigationCoordinator.navigateToArtist(artist)
                }
            )
        case .songs:
            SongsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
        case .artists:
            ArtistsView(
                libraryVM: libraryVM,
                nowPlayingVM: nowPlayingVM,
                onArtistTap: { artist in
                    deps.navigationCoordinator.navigateToArtist(artist)
                }
            )
        case .albums:
            AlbumsView(
                libraryVM: libraryVM,
                nowPlayingVM: nowPlayingVM,
                onAlbumTap: { album in
                    deps.navigationCoordinator.navigateToAlbum(album)
                }
            )
        case .genres:
            GenresView(libraryVM: libraryVM) { _ in }
        case .playlists:
            PlaylistsView(nowPlayingVM: nowPlayingVM) { _ in }
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
    
    @ViewBuilder
    private func detailViewForDestination(destination: NavigationCoordinator.Destination) -> some View {
        // Wrap in NavigationView so detail views have a navigation bar
        NavigationView {
            Group {
                switch destination {
                case .artist(let artist):
                    ArtistDetailView(
                        artist: artist,
                        nowPlayingVM: nowPlayingVM,
                        onAlbumTap: { _ in }
                    )
                case .album(let album):
                    AlbumDetailView(
                        album: album,
                        nowPlayingVM: nowPlayingVM
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 110)
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismissDetailView()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
                #else
                ToolbarItem(placement: .navigation) {
                    Button {
                        dismissDetailView()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
                #endif
            }
        }
        #if os(iOS)
        .navigationViewStyle(.stack)
        #endif
    }

    private var syncButton: some View {
        Button {
            showingSyncPanel = true
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
        }
    }
}

// MARK: - iPad Sidebar View

@available(iOS 16.0, macOS 13.0, *)
public struct SidebarView: View {
    @StateObject private var libraryVM: LibraryViewModel
    @StateObject private var nowPlayingVM: NowPlayingViewModel
    @StateObject private var searchVM: SearchViewModel
    @Environment(\.dependencies) private var deps

    @State private var selection: SidebarSection? = .home
    @State private var showingNowPlaying = false
    @State private var showingSyncPanel = false
    @State private var showingDetailView = false
    
    // Helper to dismiss the detail view overlay
    private func dismissDetailView() {
        withAnimation(.easeInOut(duration: 0.3)) {
            showingDetailView = false
        }
        // Clear destination after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            deps.navigationCoordinator.clearDestination()
        }
    }

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

            // Sliding detail view overlay
            if showingDetailView, let destination = deps.navigationCoordinator.pendingDestination {
                detailViewForSidebar(destination: destination)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }

            // Mini player overlay (always on top)
            MiniPlayer(viewModel: nowPlayingVM) {
                showingNowPlaying = true
            }
            .background(.ultraThinMaterial)
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
        .onChange(of: deps.navigationCoordinator.pendingDestination) { destination in
            // Show detail view when navigation is requested
            withAnimation(.easeInOut(duration: 0.3)) {
                showingDetailView = destination != nil
            }
        }
        .onChange(of: selection) { _ in
            // Dismiss detail view when switching sidebar sections
            if showingDetailView {
                dismissDetailView()
            }
        }
        .onChange(of: showingSyncPanel) { isShowing in
            // Dismiss detail view when opening sync panel
            if isShowing && showingDetailView {
                dismissDetailView()
            }
        }
    }
    
    @ViewBuilder
    private func detailViewForSidebar(destination: NavigationCoordinator.Destination) -> some View {
        // Wrap in NavigationView so detail views have a navigation bar
        NavigationView {
            Group {
                switch destination {
                case .artist(let artist):
                    ArtistDetailView(
                        artist: artist,
                        nowPlayingVM: nowPlayingVM,
                        onAlbumTap: { _ in }
                    )
                case .album(let album):
                    AlbumDetailView(
                        album: album,
                        nowPlayingVM: nowPlayingVM
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 60)
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismissDetailView()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
                #else
                ToolbarItem(placement: .navigation) {
                    Button {
                        dismissDetailView()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
                #endif
            }
        }
        #if os(iOS)
        .navigationViewStyle(.stack)
        #endif
    }

    @ViewBuilder
    private var detailView: some View {
        Group {
            switch selection {
            case .home:
                NavigationStack {
                    HomeView(
                        nowPlayingVM: nowPlayingVM,
                        onAlbumTap: { album in
                            deps.navigationCoordinator.navigateToAlbum(album)
                        },
                        onArtistTap: { artist in
                            deps.navigationCoordinator.navigateToArtist(artist)
                        }
                    )
                }
            case .songs:
                NavigationStack {
                    SongsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
                }
            case .artists:
                NavigationStack {
                    ArtistsView(
                        libraryVM: libraryVM,
                        nowPlayingVM: nowPlayingVM
                    ) { artist in
                        deps.navigationCoordinator.navigateToArtist(artist)
                    }
                }
            case .albums:
                NavigationStack {
                    AlbumsView(
                        libraryVM: libraryVM,
                        nowPlayingVM: nowPlayingVM
                    ) { album in
                        deps.navigationCoordinator.navigateToAlbum(album)
                    }
                }
            case .genres:
                NavigationStack {
                    GenresView(libraryVM: libraryVM) { genre in
                        // Handle navigation if needed, or just let it be for now
                    }
                }
            case .playlists:
                NavigationStack {
                    PlaylistsView(nowPlayingVM: nowPlayingVM) { playlist in
                        // Handle navigation
                    }
                }
            case .favorites:
                NavigationStack {
                    FavoritesView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
                }
            case .search:
                NavigationStack {
                    SearchView(nowPlayingVM: nowPlayingVM, viewModel: searchVM)
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
}

enum SidebarSection: Hashable {
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
