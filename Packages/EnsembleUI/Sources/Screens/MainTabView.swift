import EnsembleCore
import SwiftUI

// MARK: - Tab View Factory

struct TabViewFactory {
    @MainActor
    @ViewBuilder
    static func viewContent(
        for tab: TabItem,
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        searchVM: SearchViewModel,
        isMoreRoot: Bool = false
    ) -> some View {
        if isMoreRoot {
            MoreView(
                libraryVM: libraryVM,
                nowPlayingVM: nowPlayingVM
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
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor
    @Environment(\.dependencies) private var deps
    
    @Namespace private var playerNamespace
    private let artworkAnimationID = "nowPlayingArtwork"
    
    #if os(iOS)
    @StateObject private var keyboard = KeyboardObserver()
    #endif

    @State private var showingNowPlaying = false
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
        GeometryReader { geometry in
            // Keep mini-player spacing aligned with the active tab bar style.
            let miniPlayerBottomLift: CGFloat = {
                if #available(iOS 18.0, *) {
                    return 52
                } else {
                    return 52 + geometry.safeAreaInsets.bottom
                }
            }()

            let rootView = ZStack(alignment: .bottom) {
                // Main content layer with TabView
                VStack(spacing: 0) {
                    // Connection status banner at top
                    if !isImmersiveMode {
                        ConnectionStatusBanner(networkState: networkMonitor.networkState)
                    }
                    
                    tabBarVisibility(
                        TabView(selection: tabBinding) {
                            ForEach(barTabs) { tab in
                                tabRootView(for: tab)
                                    .tag(tab)
                                    .tabItem {
                                        Label(tab.displayTitle, systemImage: tab.systemImage)
                                    }
                            }

                            tabRootView(for: .settings, isMoreRoot: true)
                                .tag(TabItem.settings)
                                .tabItem {
                                    Label("More", systemImage: "ellipsis")
                                }
                        },
                        isHidden: isImmersiveMode
                    )
                    .applyTabViewStyle(sidebarAdaptable: useSidebarAdaptable)
                }
                // iOS 15: set additionalSafeAreaInsets on each tab's navigation controller
                // so content scrolls behind the tab bar with proper mini player clearance.
                // The 70pt covers the mini player height + spacing above the tab bar.
                .miniPlayerContainerInset(
                    70,
                    isVisible: !showingNowPlaying && !isKeyboardVisible && !isImmersiveMode
                        && nowPlayingVM.currentTrack != nil
                )
                .zIndex(0)

                // MiniPlayer + PlaybackProgressBar extracted into sub-view so
                // MainTabView body has no NVM-dependent branching. Body still
                // re-evaluates (because of @StateObject) but produces a stable
                // view tree — SwiftUI can efficiently skip diffing the content.
                MainTabNowPlayingOverlay(
                    nowPlayingVM: nowPlayingVM,
                    showingNowPlaying: $showingNowPlaying,
                    isImmersiveMode: isImmersiveMode,
                    isKeyboardVisible: isKeyboardVisible,
                    namespace: playerNamespace,
                    animationID: artworkAnimationID,
                    accentColor: settingsManager.accentColor.color,
                    miniPlayerBottomLift: miniPlayerBottomLift
                )
            }
            .task {
                // Sync selectedTab with the actual first visible tab on launch.
                // selectedTab defaults to .home, but the user may have reordered
                // tabs so .home isn't in the bar — causing navigateFromNowPlaying
                // to target the wrong tab until a manual tab switch.
                if !didSetInitialTab {
                    didSetInitialTab = true
                    let firstTab = barTabs.first ?? .home
                    if navigationCoordinator.selectedTab != firstTab {
                        navigationCoordinator.selectedTab = firstTab
                    }
                }
                await libraryVM.refresh()
            }
            .onChange(of: showingNowPlaying) { isShowing in
                // Execute pending navigation after the sheet fully dismisses.
                // The 0.35s delay lets the NavigationStack settle after the
                // sheet animation completes so path mutations are not dropped.
                if !isShowing, let pending = navigationCoordinator.pendingNavigation {
                    navigationCoordinator.pendingNavigation = nil
                    navigationCoordinator.selectedTab = pending.tab
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        navigationCoordinator.push(pending.destination, in: pending.tab)
                    }
                }
            }
            .sheet(isPresented: $showingNowPlaying) {
                NowPlayingSheetView(
                    viewModel: nowPlayingVM,
                    namespace: playerNamespace,
                    animationID: artworkAnimationID,
                    dismissAction: {
                        showingNowPlaying = false
                    }
                )
                .accentColor(settingsManager.accentColor.color)
            }
            // Add account sheet presented at root level so it survives
            // TabView content recreation on iOS 15 foreground transitions
            .sheet(isPresented: $navigationCoordinator.showingAddAccount) {
                AddPlexAccountView()
                #if os(macOS)
                    .frame(width: 720, height: 560)
                #endif
            }

            applyChromeVisibilityObservation(to: rootView)
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

    @ViewBuilder
    private func applyChromeVisibilityObservation<Content: View>(to content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            content.onPreferenceChange(ChromeVisibilityPreferenceKey.self) { isHidden in
                // Avoid iOS 15/16 transition re-entrancy while Now Playing is presenting.
                guard !showingNowPlaying else { return }

                if isImmersiveMode != isHidden {
                    isImmersiveMode = isHidden
                }
            }
        } else {
            // iOS 15 fallback: skip preference observation to avoid recursive
            // HostPreferences updates that can crash during modal presentation.
            content
        }
        #else
        content.onPreferenceChange(ChromeVisibilityPreferenceKey.self) { isHidden in
            if isImmersiveMode != isHidden {
                isImmersiveMode = isHidden
            }
        }
        #endif
    }
    
    /// Whether to use .sidebarAdaptable TabView style (iPad only on iOS 18+).
    /// On iPhone, .sidebarAdaptable has a known bug (FB11710323) where
    /// NavigationStack doesn't observe programmatic state changes until
    /// a tab switch occurs. It gives the same visual tab bar as .automatic
    /// on iPhone, so there's no downside to skipping it there.
    private var useSidebarAdaptable: Bool {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            return UIDevice.current.userInterfaceIdiom == .pad
        }
        #endif
        return false
    }
    
    private var tabBinding: Binding<TabItem> {
        Binding(
            get: { navigationCoordinator.selectedTab },
            set: { handleTabTap($0) }
        )
    }
    
    private func handleTabTap(_ tag: TabItem) {
        if navigationCoordinator.selectedTab == tag {
            // Already on this tab — pop to root or focus search
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
        Group {
            if #available(iOS 16.0, macOS 13.0, *) {
                NavigationStack(path: pathBinding(for: tab)) {
                    tabContentView(for: tab, isMoreRoot: isMoreRoot)
                }
            } else {
                NavigationView {
                    // iOS 15 Fallback: Support nested navigation by passing the remaining path
                    TabViewFactory.viewContent(
                        for: tab,
                        libraryVM: libraryVM,
                        nowPlayingVM: nowPlayingVM,
                        searchVM: searchVM,
                        isMoreRoot: isMoreRoot
                    )
                    .auroraBackgroundSupport()
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
        .overlay(alignment: .bottom) {
            if settingsManager.auroraVisualizationEnabled {
                AuroraVisualizationView(
                    playbackService: DependencyContainer.shared.playbackService,
                    accentColor: settingsManager.accentColor.color,
                    isPaused: showingNowPlaying,
                    isLowPowerMode: powerStateMonitor.isLowPowerMode
                )
                .ignoresSafeArea(.all)
                .allowsHitTesting(false)
            }
        }
    }

    private func pathBinding(for tab: TabItem) -> Binding<[NavigationCoordinator.Destination]> {
        switch tab {
        case .home: return $navigationCoordinator.homePath
        case .songs: return $navigationCoordinator.songsPath
        case .artists: return $navigationCoordinator.artistsPath
        case .albums: return $navigationCoordinator.albumsPath
        case .genres: return $navigationCoordinator.genresPath
        case .playlists: return $navigationCoordinator.playlistsPath
        case .favorites: return $navigationCoordinator.favoritesPath
        case .search: return $navigationCoordinator.searchPath
        case .downloads: return $navigationCoordinator.downloadsPath
        case .settings: return $navigationCoordinator.settingsPath
        }
    }

    private func pathForTab(_ tab: TabItem) -> [NavigationCoordinator.Destination] {
        switch tab {
        case .home: return navigationCoordinator.homePath
        case .songs: return navigationCoordinator.songsPath
        case .artists: return navigationCoordinator.artistsPath
        case .albums: return navigationCoordinator.albumsPath
        case .genres: return navigationCoordinator.genresPath
        case .playlists: return navigationCoordinator.playlistsPath
        case .favorites: return navigationCoordinator.favoritesPath
        case .search: return navigationCoordinator.searchPath
        case .downloads: return navigationCoordinator.downloadsPath
        case .settings: return navigationCoordinator.settingsPath
        }
    }

    /// Tab content with navigation destinations registered for path-based push.
    @available(iOS 16.0, macOS 13.0, *)
    @ViewBuilder
    private func tabContentView(for tab: TabItem, isMoreRoot: Bool = false) -> some View {
        TabViewFactory.viewContent(
            for: tab,
            libraryVM: libraryVM,
            nowPlayingVM: nowPlayingVM,
            searchVM: searchVM,
            isMoreRoot: isMoreRoot
        )
        .auroraBackgroundSupport()
        .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
            destinationView(for: destination)
                .auroraBackgroundSupport()
        }
    }

    @ViewBuilder
    private func destinationView(for destination: NavigationCoordinator.Destination) -> some View {
        switch destination {
        case .artist(let id):
            ArtistDetailLoader(artistId: id, nowPlayingVM: nowPlayingVM)
        case .album(let id):
            AlbumDetailLoader(albumId: id, nowPlayingVM: nowPlayingVM)
        case .playlist(let id, let sourceKey):
            PlaylistDetailLoader(playlistId: id, playlistSourceKey: sourceKey, nowPlayingVM: nowPlayingVM)
        case .moodTracks(let mood):
            MoodTracksView(mood: mood, nowPlayingVM: nowPlayingVM)
        case .view(let tab):
            TabViewFactory.viewContent(
                for: tab,
                libraryVM: libraryVM,
                nowPlayingVM: nowPlayingVM,
                searchVM: searchVM,
            )
        }
    }
}

// MARK: - Now Playing Overlay

/// Extracted sub-view that owns the NVM observation for MiniPlayer and
/// PlaybackProgressBar. MainTabView's body no longer branches on NVM
/// properties, so SwiftUI can skip diffing the full TabView tree when
/// NVM publishes.
private struct MainTabNowPlayingOverlay: View {
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @Binding var showingNowPlaying: Bool
    let isImmersiveMode: Bool
    let isKeyboardVisible: Bool
    var namespace: Namespace.ID
    let animationID: String
    let accentColor: Color
    let miniPlayerBottomLift: CGFloat

    var body: some View {
        // Persistent MiniPlayer (above tab bar)
        if !showingNowPlaying && !isKeyboardVisible && !isImmersiveMode {
            let isFloating: Bool = {
                #if os(iOS)
                if #available(iOS 18.0, *) {
                    return true
                }
                #endif
                return false
            }()

            MiniPlayer(
                viewModel: nowPlayingVM,
                isFloating: isFloating,
                namespace: namespace,
                animationID: animationID
            ) {
                withAnimation(.interactiveSpring(response: 0.45, dampingFraction: 0.85)) {
                    showingNowPlaying = true
                }
            }
            .accentColor(accentColor)
            .alignmentGuide(.bottom) { dimensions in
                dimensions[.bottom] + miniPlayerBottomLift
            }
            .zIndex(2)
            .transition(.asymmetric(
                insertion: .opacity.animation(.easeInOut.delay(0.1)),
                removal: .identity
            ))
        }

        // Full-width playback progress bar pinned to the very bottom of the screen.
        // Sits above the aurora, below the mini player and tab bar.
        if nowPlayingVM.currentTrack != nil && !showingNowPlaying && !isImmersiveMode {
            PlaybackProgressBar(viewModel: nowPlayingVM)
                .ignoresSafeArea(.all, edges: .bottom)
                .zIndex(1)
                .transition(.opacity)
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
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor
    @Environment(\.dependencies) private var deps

    @Namespace private var playerNamespace
    private let artworkAnimationID = "nowPlayingArtwork"

    @State private var selection: SidebarSection? = .home
    @State private var showingNowPlaying = false

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
                    }
                }
                .listStyle(.sidebar)
                .navigationTitle("Ensemble")
            } detail: {
                detailView
            }

            // Mini player overlay (always on top)
            if !showingNowPlaying {
                MiniPlayer(
                    viewModel: nowPlayingVM,
                    isFloating: true,
                    namespace: playerNamespace,
                    animationID: artworkAnimationID
                ) {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        showingNowPlaying = true
                    }
                }
                .accentColor(deps.settingsManager.accentColor.color)
                .zIndex(2)
                .transition(.identity) // Use identity to let matchedGeometry handle the morph
            }

        }
        .onChange(of: showingNowPlaying) { isShowing in
            // Execute pending navigation after sheet fully dismisses.
            if !isShowing, let pending = navigationCoordinator.pendingNavigation {
                navigationCoordinator.pendingNavigation = nil
                // Switch sidebar to the matching section
                let targetTab = self.targetTab(for: pending.destination)
                self.selection = self.sidebarSection(for: pending.destination)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    navigationCoordinator.push(pending.destination, in: targetTab)
                }
            }
        }
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingSheetView(
                viewModel: nowPlayingVM,
                namespace: playerNamespace,
                animationID: artworkAnimationID,
                dismissAction: {
                    showingNowPlaying = false
                }
            )
            .accentColor(deps.settingsManager.accentColor.color)
        }
        // Add account sheet presented at root level so it survives
        // view content recreation on foreground transitions
        .sheet(isPresented: $navigationCoordinator.showingAddAccount) {
            AddPlexAccountView()
            #if os(macOS)
                .frame(width: 720, height: 560)
            #endif
        }
        .task {
            await libraryVM.refresh()
            await pinnedVM.loadPinnedItems()
        }
        // Keep NavigationCoordinator.selectedTab in sync with sidebar selection
        // so navigate(to:) pushes onto the correct section's NavigationStack
        .onChange(of: selection) { newSelection in
            if let tab = newSelection?.correspondingTab {
                navigationCoordinator.selectedTab = tab
            }
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

    /// Map a navigation destination to the sidebar section that should be selected
    private func sidebarSection(for destination: NavigationCoordinator.Destination) -> SidebarSection {
        switch destination {
        case .artist: return .artists
        case .album: return .albums
        case .playlist: return .playlists
        case .moodTracks: return .home
        case .view(let tab):
            switch tab {
            case .home: return .home
            case .songs: return .songs
            case .artists: return .artists
            case .albums: return .albums
            case .genres: return .genres
            case .playlists: return .playlists
            case .favorites: return .favorites
            case .search: return .search
            case .downloads: return .downloads
            case .settings: return .settings
            }
        }
    }

    /// Map a navigation destination to the tab whose NavigationStack should receive the push
    private func targetTab(for destination: NavigationCoordinator.Destination) -> TabItem {
        switch destination {
        case .artist: return .artists
        case .album: return .albums
        case .playlist: return .playlists
        case .moodTracks: return .home
        case .view(let tab): return tab
        }
    }

    
    @ViewBuilder
    private var detailView: some View {
        Group {
            switch selection {
            case .home:
                NavigationStack(path: $navigationCoordinator.homePath) {
                    sidebarContentView(for: .home)
                }
            case .songs:
                NavigationStack {
                    TabViewFactory.viewContent(for: .songs, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM)
                }
            case .artists:
                NavigationStack(path: $navigationCoordinator.artistsPath) {
                    sidebarContentView(for: .artists)
                }
            case .albums:
                NavigationStack(path: $navigationCoordinator.albumsPath) {
                    sidebarContentView(for: .albums)
                }
            case .genres:
                NavigationStack {
                    TabViewFactory.viewContent(for: .genres, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM)
                }
            case .playlists:
                NavigationStack(path: $navigationCoordinator.playlistsPath) {
                    sidebarContentView(for: .playlists)
                }
            case .favorites:
                NavigationStack {
                    TabViewFactory.viewContent(for: .favorites, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM)
                }
            case .search:
                NavigationStack(path: $navigationCoordinator.searchPath) {
                    sidebarContentView(for: .search)
                }
            case .downloads:
                NavigationStack {
                    TabViewFactory.viewContent(for: .downloads, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM)
                }
            case .settings:
                NavigationStack {
                    TabViewFactory.viewContent(for: .settings, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM)
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
                        PlaylistDetailLoader(playlistId: id, playlistSourceKey: nil, nowPlayingVM: nowPlayingVM)
                    }
                }
            case .none:
                Text("Select a section")
                    .foregroundColor(.secondary)
            }
        }
        .auroraBackgroundSupport()
        .overlay(alignment: .bottom) {
            if settingsManager.auroraVisualizationEnabled {
                AuroraVisualizationView(
                    playbackService: DependencyContainer.shared.playbackService,
                    accentColor: settingsManager.accentColor.color,
                    isPaused: showingNowPlaying,
                    isLowPowerMode: powerStateMonitor.isLowPowerMode
                )
                .ignoresSafeArea(.all)
                .allowsHitTesting(false)
            }
        }
        .miniPlayerBottomSpacing(64)
    }
    
    /// Sidebar section content with navigation destinations registered for path-based push
    @ViewBuilder
    private func sidebarContentView(for tab: TabItem) -> some View {
        TabViewFactory.viewContent(for: tab, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM)
            .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                destinationView(for: destination)
            }
    }

    @ViewBuilder
    private func destinationView(for destination: NavigationCoordinator.Destination) -> some View {
        switch destination {
        case .artist(let id):
            ArtistDetailLoader(artistId: id, nowPlayingVM: nowPlayingVM)
        case .album(let id):
            AlbumDetailLoader(albumId: id, nowPlayingVM: nowPlayingVM)
        case .playlist(let id, let sourceKey):
            PlaylistDetailLoader(playlistId: id, playlistSourceKey: sourceKey, nowPlayingVM: nowPlayingVM)
        case .moodTracks(let mood):
            MoodTracksView(mood: mood, nowPlayingVM: nowPlayingVM)
        case .view(let tab):
            TabViewFactory.viewContent(
                for: tab,
                libraryVM: libraryVM,
                nowPlayingVM: nowPlayingVM,
                searchVM: searchVM
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

    /// Map sidebar section to the corresponding TabItem for NavigationCoordinator sync.
    /// Returns nil for pinned items which don't map to a standard tab.
    var correspondingTab: TabItem? {
        switch self {
        case .home: return .home
        case .songs: return .songs
        case .artists: return .artists
        case .albums: return .albums
        case .genres: return .genres
        case .playlists: return .playlists
        case .favorites: return .favorites
        case .search: return .search
        case .downloads: return .downloads
        case .settings: return .settings
        case .pin: return nil
        }
    }
}

// MARK: - TabView Style Helper

extension View {
    /// Apply .sidebarAdaptable or .automatic TabView style.
    /// Needed because different styles are different types and can't be
    /// returned from a single `some TabViewStyle` function.
    @ViewBuilder
    func applyTabViewStyle(sidebarAdaptable: Bool) -> some View {
        #if os(iOS)
        if sidebarAdaptable {
            if #available(iOS 18.0, *) {
                self.tabViewStyle(.sidebarAdaptable)
            } else {
                self.tabViewStyle(.automatic)
            }
        } else {
            self.tabViewStyle(.automatic)
        }
        #else
        self.tabViewStyle(.automatic)
        #endif
    }
}
