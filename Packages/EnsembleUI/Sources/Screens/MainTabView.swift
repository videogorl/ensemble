import EnsembleCore
import SwiftUI

/// Main tab bar view for iPhone (5-tab classic iOS style)
public struct MainTabView: View {
    @StateObject private var libraryVM: LibraryViewModel
    @StateObject private var nowPlayingVM: NowPlayingViewModel
    @Environment(\.dependencies) private var deps

    @State private var selectedTab = 0
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
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Main content layer (TabView)
                TabView(selection: $selectedTab) {
                    // Home
                    NavigationView {
                        HomeView(
                            nowPlayingVM: nowPlayingVM,
                            onAlbumTap: { _ in },
                            onArtistTap: { _ in }
                        )
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                syncButton
                            }
                        }
                    }
                    .navigationViewStyle(.stack)
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: nowPlayingVM.hasCurrentTrack ? 110 : 49)
                    }
                    .tag(0)

                    // Artists
                    NavigationView {
                        ArtistsView(
                            libraryVM: libraryVM,
                            nowPlayingVM: nowPlayingVM,
                            onArtistTap: { artist in
                                // Navigation handled by ArtistsView
                            }
                        )
                    }
                    .navigationViewStyle(.stack)
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: nowPlayingVM.hasCurrentTrack ? 110 : 49)
                    }
                    .tag(1)

                    // Playlists
                    NavigationView {
                        PlaylistsView(nowPlayingVM: nowPlayingVM) { playlist in
                            // Navigation handled by PlaylistsView
                        }
                    }
                    .navigationViewStyle(.stack)
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: nowPlayingVM.hasCurrentTrack ? 110 : 49)
                    }
                    .tag(2)

                    // Search
                    NavigationView {
                        SearchView(nowPlayingVM: nowPlayingVM)
                    }
                    .navigationViewStyle(.stack)
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: nowPlayingVM.hasCurrentTrack ? 110 : 49)
                    }
                    .tag(3)

                    // More
                    NavigationView {
                        MoreView(
                            libraryVM: libraryVM,
                            nowPlayingVM: nowPlayingVM
                        )
                    }
                    .navigationViewStyle(.stack)
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: nowPlayingVM.hasCurrentTrack ? 110 : 49)
                    }
                    .tag(4)
                }
                // Hide the standard tab bar since we're using a custom one for layering
                .onAppear {
                    let appearance = UITabBarAppearance()
                    appearance.configureWithTransparentBackground()
                    UITabBar.appearance().standardAppearance = appearance
                    UITabBar.appearance().scrollEdgeAppearance = appearance
                }

                // Sliding detail view overlay
                if showingDetailView, let destination = deps.navigationCoordinator.pendingDestination {
                    detailViewForDestination(destination: destination)
                        .transition(.move(edge: .trailing))
                        .zIndex(1)
                }

                // Persistent UI Layer (MiniPlayer + Custom TabBar)
                VStack(spacing: 0) {
                    if nowPlayingVM.hasCurrentTrack {
                        MiniPlayer(viewModel: nowPlayingVM) {
                            showingNowPlaying = true
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

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
            tabItem(title: "Home", icon: "house", tag: 0)
            tabItem(title: "Artists", icon: "music.mic", tag: 1)
            tabItem(title: "Playlists", icon: "music.note.list", tag: 2)
            tabItem(title: "Search", icon: "magnifyingglass", tag: 3)
            tabItem(title: "More", icon: "ellipsis", tag: 4)
        }
        .frame(height: 49)
        .padding(.bottom, safeAreaBottom > 0 ? safeAreaBottom : 8)
    }
    
    private func tabItem(title: String, icon: String, tag: Int) -> some View {
        Button {
            selectedTab = tag
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(title)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .foregroundColor(selectedTab == tag ? .accentColor : .secondary)
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
                Color.clear.frame(height: nowPlayingVM.hasCurrentTrack ? 110 : 49)
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismissDetailView()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
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

@available(iOS 16.0, *)
public struct SidebarView: View {
    @StateObject private var libraryVM: LibraryViewModel
    @StateObject private var nowPlayingVM: NowPlayingViewModel
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
                    }
                }
                .listStyle(.sidebar)
                .navigationTitle("Ensemble")
                .toolbar {
                    ToolbarItem {
                        Button {
                            showingSyncPanel = true
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                }
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
            if nowPlayingVM.hasCurrentTrack {
                MiniPlayer(viewModel: nowPlayingVM) {
                    showingNowPlaying = true
                }
                .background(.ultraThinMaterial)
                .zIndex(2)
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
                if nowPlayingVM.hasCurrentTrack {
                    Color.clear.frame(height: 60)
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismissDetailView()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .home:
            NavigationStack {
                HomeView(
                    nowPlayingVM: nowPlayingVM,
                    onAlbumTap: { _ in },
                    onArtistTap: { _ in }
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
                    // Handle navigation
                }
            }
        case .albums:
            NavigationStack {
                AlbumsView(
                    libraryVM: libraryVM,
                    nowPlayingVM: nowPlayingVM
                ) { album in
                    // Handle navigation
                }
            }
        case .genres:
            NavigationStack {
                GenresView(libraryVM: libraryVM) { genre in
                    // Handle navigation
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
                SearchView(nowPlayingVM: nowPlayingVM)
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
