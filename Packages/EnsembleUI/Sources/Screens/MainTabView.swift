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

    public init() {
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self._nowPlayingVM = StateObject(wrappedValue: DependencyContainer.shared.makeNowPlayingViewModel())
    }

    public var body: some View {
        ZStack {
            // Main tab view
            ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                // Songs
                NavigationView {
                    SongsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                syncButton
                            }
                        }
                }
                .navigationViewStyle(.stack)
                .tabItem {
                    Label("Songs", systemImage: "music.note")
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
                .tabItem {
                    Label("Artists", systemImage: "music.mic")
                }
                .tag(1)

                // Playlists
                NavigationView {
                    PlaylistsView(nowPlayingVM: nowPlayingVM) { playlist in
                        // Navigation handled by PlaylistsView
                    }
                }
                .navigationViewStyle(.stack)
                .tabItem {
                    Label("Playlists", systemImage: "music.note.list")
                }
                .tag(2)

                // Search
                NavigationView {
                    SearchView(nowPlayingVM: nowPlayingVM)
                }
                .navigationViewStyle(.stack)
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
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
                .tabItem {
                    Label("More", systemImage: "ellipsis")
                }
                .tag(4)
            }

            // Mini player overlay
            if nowPlayingVM.hasCurrentTrack {
                VStack(spacing: 0) {
                    Spacer()

                    MiniPlayer(viewModel: nowPlayingVM) {
                        showingNowPlaying = true
                    }

                    // Tab bar spacer
                    Color.clear
                        .frame(height: 49)
                }
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
            
            // Sliding detail view overlay
            if showingDetailView, let destination = deps.navigationCoordinator.pendingDestination {
                detailViewForDestination(destination: destination)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
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
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showingDetailView = false
                        }
                        // Clear destination after animation
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            deps.navigationCoordinator.clearDestination()
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                        Text("Back")
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

    @State private var selection: SidebarSection? = .songs
    @State private var showingNowPlaying = false
    @State private var showingSyncPanel = false
    @State private var showingDetailView = false

    public init() {
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self._nowPlayingVM = StateObject(wrappedValue: DependencyContainer.shared.makeNowPlayingViewModel())
    }

    public var body: some View {
        ZStack {
            // Main split view
            NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
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
            
            // Sliding detail view overlay
            if showingDetailView, let destination = deps.navigationCoordinator.pendingDestination {
                detailViewForSidebar(destination: destination)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
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
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showingDetailView = false
                        }
                        // Clear destination after animation
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            deps.navigationCoordinator.clearDestination()
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
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
    case songs
    case artists
    case albums
    case genres
    case playlists
    case search
    case downloads
    case settings
}
