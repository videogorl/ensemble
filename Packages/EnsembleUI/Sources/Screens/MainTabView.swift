import EnsembleCore
import SwiftUI

/// Main tab bar view for iPhone (5-tab classic iOS style)
public struct MainTabView: View {
    @StateObject private var libraryVM: LibraryViewModel
    @StateObject private var nowPlayingVM: NowPlayingViewModel
    @ObservedObject var authViewModel: AuthViewModel

    @State private var selectedTab = 0
    @State private var showingNowPlaying = false

    public init(authViewModel: AuthViewModel) {
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self._nowPlayingVM = StateObject(wrappedValue: DependencyContainer.shared.makeNowPlayingViewModel())
        self.authViewModel = authViewModel
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                // Songs
                NavigationView {
                    SongsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
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
                        nowPlayingVM: nowPlayingVM,
                        authViewModel: authViewModel
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
        .task {
            await libraryVM.refresh()
        }
    }
}

// MARK: - iPad Sidebar View

@available(iOS 16.0, *)
public struct SidebarView: View {
    @StateObject private var libraryVM: LibraryViewModel
    @StateObject private var nowPlayingVM: NowPlayingViewModel
    @ObservedObject var authViewModel: AuthViewModel

    @State private var selection: SidebarSection? = .songs
    @State private var showingNowPlaying = false

    public init(authViewModel: AuthViewModel) {
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self._nowPlayingVM = StateObject(wrappedValue: DependencyContainer.shared.makeNowPlayingViewModel())
        self.authViewModel = authViewModel
    }

    public var body: some View {
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
        } detail: {
            detailView
        }
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingView(viewModel: nowPlayingVM)
        }
        .task {
            await libraryVM.refresh()
        }
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
                ArtistsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM) { artist in
                    // Handle navigation
                }
            }
        case .albums:
            NavigationStack {
                AlbumsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM) { album in
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
                SettingsView(authViewModel: authViewModel)
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
