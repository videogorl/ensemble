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
    // Observation-extracted: networkMonitor publishes on every network state change,
    // which would invalidate the entire root view. We only need networkState, so we
    // listen to just that property and store it in @State.
    private let networkMonitor = DependencyContainer.shared.networkMonitor
    @ObservedObject private var navigationCoordinator = DependencyContainer.shared.navigationCoordinator
    // Observation-extracted: only isLowPowerMode is used, avoid root view invalidation
    private let powerStateMonitor = DependencyContainer.shared.powerStateMonitor
    @Environment(\.dependencies) private var deps
    @Environment(\.isViewportNowPlayingPresented) private var isViewportNowPlayingPresented
    @Environment(\.presentViewportNowPlaying) private var presentViewportNowPlaying

    @Namespace private var playerNamespace
    private let artworkAnimationID = "nowPlayingArtwork"
    
    #if os(iOS)
    @StateObject private var keyboard = KeyboardObserver()
    #endif

    @State private var showingSheetNowPlaying = false
    @State private var didSetInitialTab = false
    @State private var isImmersiveMode = false
    // Extracted observation state — avoids full root invalidation from singleton publishers
    @State private var networkState: NetworkState = DependencyContainer.shared.networkMonitor.networkState
    @State private var isLowPowerMode: Bool = DependencyContainer.shared.powerStateMonitor.isLowPowerMode

    // Get the tabs to show in the bar (limit to 4, then More)
    private var barTabs: [TabItem] {
        Array(settingsManager.enabledTabs.prefix(4))
    }

    public init() {
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self._nowPlayingVM = StateObject(wrappedValue: DependencyContainer.shared.makeNowPlayingViewModel())
        self._searchVM = StateObject(wrappedValue: DependencyContainer.shared.makeSearchViewModel())
    }

    private var usesViewportNowPlayingPresentation: Bool {
        #if os(macOS)
        return true
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    private var isKeyboardVisible: Bool {
        #if os(iOS)
        return keyboard.isVisible
        #else
        return false
        #endif
    }

    private var isShowingNowPlaying: Bool {
        usesViewportNowPlayingPresentation ? isViewportNowPlayingPresented : showingSheetNowPlaying
    }

    public var body: some View {
        GeometryReader { geometry in
            // Keep mini-player spacing aligned with the active tab bar style.
            let miniPlayerBottomLift: CGFloat = {
                if #available(iOS 18.0, *) {
                    return TrackListLayoutMetrics.miniPlayerBottomLiftBase
                } else {
                    return TrackListLayoutMetrics.miniPlayerBottomLiftBase + geometry.safeAreaInsets.bottom
                }
            }()

            let rootView = ZStack(alignment: .bottom) {
                // Main content layer with TabView
                VStack(spacing: 0) {
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
                    TrackListLayoutMetrics.miniPlayerContainerInset,
                    isVisible: !isShowingNowPlaying && !isKeyboardVisible && !isImmersiveMode
                )
                .zIndex(0)

                // MiniPlayer extracted into sub-view so MainTabView body has
                // no NVM-dependent branching. Body still re-evaluates (because
                // of @StateObject) but produces a stable view tree — SwiftUI
                // can efficiently skip diffing the content.
                MainTabNowPlayingOverlay(
                    nowPlayingVM: nowPlayingVM,
                    showingNowPlaying: Binding(
                        get: { isShowingNowPlaying },
                        set: { newValue in
                            if usesViewportNowPlayingPresentation {
                                if newValue {
                                    presentViewportNowPlaying(nowPlayingVM)
                                }
                            } else {
                                showingSheetNowPlaying = newValue
                            }
                        }
                    ),
                    isImmersiveMode: isImmersiveMode,
                    isKeyboardVisible: isKeyboardVisible,
                    namespace: playerNamespace,
                    animationID: artworkAnimationID,
                    accentColor: settingsManager.accentColor.color,
                    miniPlayerBottomLift: miniPlayerBottomLift
                )
            }
            .onAppear {
                // Register the active NowPlayingViewModel so the external display
                // SceneDelegate (AirPlay screen mirroring) can observe the same instance.
                DependencyContainer.shared.activeNowPlayingViewModel = nowPlayingVM
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
            // Observation-extracted receivers — update @State only when specific values change,
            // avoiding full root view invalidation from singleton objectWillChange.
            .onReceive(networkMonitor.$networkState) { newValue in
                networkState = newValue
            }
            .onReceive(powerStateMonitor.$isLowPowerMode) { newValue in
                isLowPowerMode = newValue
            }
            .onChange(of: isShowingNowPlaying) { isShowing in
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
            .if(!usesViewportNowPlayingPresentation) { view in
                view.sheet(isPresented: $showingSheetNowPlaying) {
                    NowPlayingSheetView(
                        viewModel: nowPlayingVM,
                        namespace: playerNamespace,
                        animationID: artworkAnimationID,
                        dismissAction: {
                            showingSheetNowPlaying = false
                        }
                    )
                    .accentColor(settingsManager.accentColor.color)
                }
            }
            #if os(iOS)
            .sheet(item: $navigationCoordinator.activeAuxiliaryPresentation, onDismiss: {
                navigationCoordinator.dismissAuxiliaryPresentation()
            }) { destination in
                AuxiliaryPresentationView(destination: destination)
                    .accentColor(settingsManager.accentColor.color)
            }
            #endif
            // Add account sheet presented at root level so it survives
            // TabView content recreation on iOS 15 foreground transitions
            .sheet(isPresented: $navigationCoordinator.showingAddAccount) {
                AddPlexAccountView()
                #if os(macOS)
                    .frame(width: 720, height: 560)
                #endif
            }

            applyChromeVisibilityObservation(
                to: rootView
                    .overlay(alignment: .top) {
                        if !isImmersiveMode {
                            OfflineIndicatorOverlay(
                                networkState: networkState,
                                topInset: geometry.safeAreaInsets.top
                            )
                        }
                    }
            )
        }
    }

    @ViewBuilder
    private func tabBarVisibility<Content: View>(_ content: Content, isHidden: Bool) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            content.toolbar(isHidden ? .hidden : .visible, for: .tabBar)
        } else {
            // iOS 15: hide tab bar via UIKit since .toolbar(_, for: .tabBar) is unavailable
            content.background(
                iOS15TabBarHider(isHidden: isHidden)
            )
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
                guard !isShowingNowPlaying else { return }

                if isImmersiveMode != isHidden {
                    isImmersiveMode = isHidden
                }
            }
        } else {
            // iOS 15: preference observation causes recursive HostPreferences crashes
            // during modal presentation. Use notification-based approach instead.
            content
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: AppOrientationNotifications.stageFlowImmersiveModeChanged
                    )
                ) { notification in
                    guard let isHidden = notification.object as? Bool else { return }
                    guard !isShowingNowPlaying else { return }
                    if isImmersiveMode != isHidden {
                        isImmersiveMode = isHidden
                    }
                }
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
            if settingsManager.auroraVisualizationEnabled && !isImmersiveMode {
                AuroraVisualizationView(
                    playbackService: DependencyContainer.shared.playbackService,
                    accentColor: settingsManager.accentColor.color,
                    isPaused: isShowingNowPlaying,
                    isLowPowerMode: isLowPowerMode
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
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                ProfileToolbarButton()
            }
        }
        #endif
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
        case .mergedPlaylist(let title, let isSmart):
            MergedPlaylistDetailLoader(title: title, isSmart: isSmart, nowPlayingVM: nowPlayingVM)
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

/// Extracted sub-view that owns the NVM observation for MiniPlayer.
/// MainTabView's body no longer branches on NVM properties, so SwiftUI
/// can skip diffing the full TabView tree when NVM publishes.
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
        }

    }
}

// MARK: - iOS 15 Tab Bar Hider

#if os(iOS)
/// Hides the UITabBar on iOS 15 where .toolbar(_, for: .tabBar) is unavailable.
/// Searches from the window's root view controller to find the UITabBarController
/// backing SwiftUI's TabView, then sets tabBar.isHidden directly.
private struct iOS15TabBarHider: UIViewRepresentable {
    let isHidden: Bool

    func makeUIView(context: Context) -> TabBarProbeView {
        let view = TabBarProbeView()
        view.targetHidden = isHidden
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ view: TabBarProbeView, context: Context) {
        view.targetHidden = isHidden
        view.applyTabBarVisibility()
    }

    final class TabBarProbeView: UIView {
        var targetHidden: Bool = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.applyTabBarVisibility()
            }
        }

        func applyTabBarVisibility() {
            guard let window = self.window,
                  let tabBarController = Self.findTabBarController(from: window.rootViewController) else {
                return
            }
            if tabBarController.tabBar.isHidden != targetHidden {
                tabBarController.tabBar.isHidden = targetHidden
            }
        }

        /// Recursively search the view controller hierarchy for the UITabBarController
        private static func findTabBarController(from vc: UIViewController?) -> UITabBarController? {
            guard let vc else { return nil }
            if let tbc = vc as? UITabBarController { return tbc }
            for child in vc.children {
                if let found = findTabBarController(from: child) { return found }
            }
            if let presented = vc.presentedViewController {
                return findTabBarController(from: presented)
            }
            return nil
        }
    }
}
#endif

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
private struct SidebarColumnWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 260

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct SidebarView: View {
    /// Stable sidebar-only playlist row model so SwiftUI diffing does not depend on
    /// the broader Playlist Hashable/Equatable semantics.
    private struct SidebarPlaylistItem: Identifiable, Equatable {
        let id: String
        let playlistID: String
        let sourceKey: String?
        let title: String
        let isSmart: Bool
        let isMerged: Bool
        let compositePath: String?
    }

    @StateObject private var libraryVM: LibraryViewModel
    @StateObject private var nowPlayingVM: NowPlayingViewModel
    @StateObject private var searchVM: SearchViewModel
    @StateObject private var pinnedVM: PinnedViewModel
    @StateObject private var playlistsVM: PlaylistViewModel
    @ObservedObject private var navigationCoordinator = DependencyContainer.shared.navigationCoordinator
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    // Observation-extracted: only isLowPowerMode is used from this monitor
    private let powerStateMonitor = DependencyContainer.shared.powerStateMonitor
    @Environment(\.dependencies) private var deps
    @Environment(\.isViewportNowPlayingPresented) private var isViewportNowPlayingPresented
    @Environment(\.presentViewportNowPlaying) private var presentViewportNowPlaying
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @Namespace private var playerNamespace
    private let artworkAnimationID = "nowPlayingArtwork"

    @State private var selection: SidebarSelection? = .library(.home)
    @State private var showingSheetNowPlaying = false
    @State private var sidebarColumnWidth: CGFloat = 260
    // Extracted observation state — avoids full root invalidation from powerStateMonitor
    @State private var isLowPowerMode: Bool = DependencyContainer.shared.powerStateMonitor.isLowPowerMode
    @SceneStorage("sidebarPinsExpanded") private var isPinsExpanded = true
    @SceneStorage("sidebarSmartPlaylistsExpanded") private var isSmartPlaylistsExpanded = true
    @SceneStorage("sidebarPlaylistsExpanded") private var isPlaylistsExpanded = true

    // Cached sidebar playlist items driven by .onReceive — avoids computed property
    // re-evaluation issues on macOS where NavigationSplitView can swallow updates.
    @State private var cachedSmartPlaylists: [SidebarPlaylistItem] = []
    @State private var cachedRegularPlaylists: [SidebarPlaylistItem] = []

    public init() {
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self._nowPlayingVM = StateObject(wrappedValue: DependencyContainer.shared.makeNowPlayingViewModel())
        self._searchVM = StateObject(wrappedValue: DependencyContainer.shared.makeSearchViewModel())
        self._pinnedVM = StateObject(wrappedValue: DependencyContainer.shared.makePinnedViewModel())
        self._playlistsVM = StateObject(wrappedValue: DependencyContainer.shared.makePlaylistViewModel())
    }

    private var usesViewportNowPlayingPresentation: Bool {
        #if os(macOS)
        return true
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    private var isShowingNowPlaying: Bool {
        usesViewportNowPlayingPresentation ? isViewportNowPlayingPresented : showingSheetNowPlaying
    }

    /// Rebuild the cached sidebar playlist @State from the VM's current data.
    /// Uses @State instead of computed properties to survive NavigationSplitView
    /// re-layouts on macOS that can drop computed property changes.
    private func rebuildCachedSidebarPlaylists() {
        let items = buildSidebarPlaylistItems()
        let newSmart = items.filter(\.isSmart)
        let newRegular = items.filter { !$0.isSmart }

        // Never replace a populated cache with empty data. The shared
        // PlaylistViewModel is also used by PlaylistsView — its .task
        // reloads with showLoading:true, which briefly sets playlists=[]
        // and fires this handler. Allowing the clear would wipe the sidebar.
        if !newSmart.isEmpty || cachedSmartPlaylists.isEmpty {
            if newSmart.map(\.id) != cachedSmartPlaylists.map(\.id) {
                cachedSmartPlaylists = newSmart
            }
        }
        if !newRegular.isEmpty || cachedRegularPlaylists.isEmpty {
            if newRegular.map(\.id) != cachedRegularPlaylists.map(\.id) {
                cachedRegularPlaylists = newRegular
            }
        }
    }

    /// Build sidebar playlist items from the VM's current playlists.
    /// When merge is enabled, uses `sortedDisplayPlaylists` to group same-named playlists.
    /// Called from rebuildCachedSidebarPlaylists to update @State caches.
    private func buildSidebarPlaylistItems() -> [SidebarPlaylistItem] {
        if playlistsVM.isMergeEnabled {
            return buildMergedSidebarPlaylistItems()
        }
        return buildIndividualSidebarPlaylistItems()
    }

    /// Build sidebar items from DisplayPlaylists (merge-aware grouping)
    private func buildMergedSidebarPlaylistItems() -> [SidebarPlaylistItem] {
        var seenIDs = Set<String>()
        return playlistsVM.sortedDisplayPlaylists.compactMap { dp in
            let stableID = dp.id
            guard seenIDs.insert(stableID).inserted else { return nil }
            return SidebarPlaylistItem(
                id: stableID,
                playlistID: dp.primaryPlaylist.id,
                sourceKey: dp.primaryPlaylist.sourceCompositeKey,
                title: dp.title,
                isSmart: dp.isSmart,
                isMerged: dp.isMerged,
                compositePath: dp.primaryPlaylist.compositePath
            )
        }
    }

    /// Build sidebar items from individual playlists (merge off)
    private func buildIndividualSidebarPlaylistItems() -> [SidebarPlaylistItem] {
        var seenIDs = Set<String>()
        let sortedPlaylists = sortedSidebarSourcePlaylists()

        return sortedPlaylists.compactMap { playlist in
            let resolvedTitle = resolvedSidebarPlaylistTitle(for: playlist)
            let playlistIdentity = playlist.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let keyIdentity = playlist.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let stableID = [
                playlistIdentity.isEmpty ? keyIdentity : playlistIdentity,
                playlist.sourceCompositeKey ?? "",
                keyIdentity,
                resolvedTitle
            ].joined(separator: "|")

            guard !stableID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                #if DEBUG
                EnsembleLogger.debug("⚠️ SidebarView: skipping playlist row with no stable identity")
                #endif
                return nil
            }

            guard seenIDs.insert(stableID).inserted else {
                return nil
            }

            return SidebarPlaylistItem(
                id: stableID,
                playlistID: playlist.id,
                sourceKey: playlist.sourceCompositeKey,
                title: resolvedTitle,
                isSmart: playlist.isSmart,
                isMerged: false,
                compositePath: playlist.compositePath
            )
        }
    }

    private func sortedSidebarSourcePlaylists() -> [Playlist] {
        let ascending = playlistsVM.filterOptions.sortDirection == .ascending

        switch playlistsVM.playlistSortOption {
        case .title:
            let keyed = playlistsVM.playlists.map { ($0, resolvedSidebarPlaylistTitle(for: $0).sortingKey) }
            return keyed.sorted {
                let result = $0.1.localizedStandardCompare($1.1)
                if result == .orderedSame {
                    return sidebarPlaylistTieBreakKey(for: $0.0) < sidebarPlaylistTieBreakKey(for: $1.0)
                }
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
            .map(\.0)
        case .trackCount:
            return playlistsVM.playlists.sorted {
                compareSidebarPlaylists($0.trackCount, $1.trackCount, ascending: ascending, lhs: $0, rhs: $1)
            }
        case .duration:
            return playlistsVM.playlists.sorted {
                compareSidebarPlaylists($0.duration, $1.duration, ascending: ascending, lhs: $0, rhs: $1)
            }
        case .dateAdded:
            return playlistsVM.playlists.sorted {
                compareSidebarPlaylists($0.dateAdded ?? .distantPast, $1.dateAdded ?? .distantPast, ascending: ascending, lhs: $0, rhs: $1)
            }
        case .dateModified:
            return playlistsVM.playlists.sorted {
                compareSidebarPlaylists($0.dateModified ?? .distantPast, $1.dateModified ?? .distantPast, ascending: ascending, lhs: $0, rhs: $1)
            }
        case .lastPlayed:
            return playlistsVM.playlists.sorted {
                compareSidebarPlaylists($0.lastPlayed ?? .distantPast, $1.lastPlayed ?? .distantPast, ascending: ascending, lhs: $0, rhs: $1)
            }
        }
    }

    private func compareSidebarPlaylists<T: Comparable>(
        _ lhsValue: T,
        _ rhsValue: T,
        ascending: Bool,
        lhs: Playlist,
        rhs: Playlist
    ) -> Bool {
        if lhsValue == rhsValue {
            return sidebarPlaylistTieBreakKey(for: lhs) < sidebarPlaylistTieBreakKey(for: rhs)
        }
        return ascending ? lhsValue < rhsValue : lhsValue > rhsValue
    }

    private func sidebarPlaylistTieBreakKey(for playlist: Playlist) -> String {
        [
            playlist.id.trimmingCharacters(in: .whitespacesAndNewlines),
            playlist.sourceCompositeKey ?? "",
            playlist.key.trimmingCharacters(in: .whitespacesAndNewlines),
            resolvedSidebarPlaylistTitle(for: playlist)
        ].joined(separator: "|")
    }

    private func resolvedSidebarPlaylistTitle(for playlist: Playlist) -> String {
        let trimmedTitle = playlist.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        let keyFallback = playlist.key
            .split(separator: "/")
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let keyFallback, !keyFallback.isEmpty {
            return keyFallback
        }

        return "Untitled Playlist"
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                // .constant(.doubleColumn) makes the binding read-only — SwiftUI
                // cannot collapse the sidebar because the write is a no-op.
                NavigationSplitView(columnVisibility: .constant(.doubleColumn)) {
                    sidebarColumn
                } detail: {
                    detailContainerView
                }
                .navigationSplitViewStyle(.balanced)

                // Aurora visualization — placed in the outer ZStack so it renders
                // above NavigationStack pushed views (macOS NavigationStack creates
                // opaque compositing layers that paint over parent overlays).
                if settingsManager.auroraVisualizationEnabled {
                    detailColumnAurora(totalSize: proxy.size)
                        .zIndex(1)
                }

                if !isShowingNowPlaying {
                    detailColumnMiniPlayer(totalSize: proxy.size)
                        .zIndex(2)
                }
            }
        }
        .onPreferenceChange(SidebarColumnWidthPreferenceKey.self) { width in
            guard abs(width - sidebarColumnWidth) > 1 else { return }
            sidebarColumnWidth = width
        }
        #if os(iOS)
        .sheet(item: $navigationCoordinator.activeAuxiliaryPresentation, onDismiss: {
            navigationCoordinator.dismissAuxiliaryPresentation()
        }) { destination in
            AuxiliaryPresentationView(destination: destination)
                .accentColor(settingsManager.accentColor.color)
        }
        #endif
        .onChange(of: isShowingNowPlaying) { isShowing in
            // Execute pending navigation after sheet fully dismisses.
            if !isShowing, let pending = navigationCoordinator.pendingNavigation {
                navigationCoordinator.pendingNavigation = nil
                // Switch sidebar to the matching section
                let targetTab = self.targetTab(for: pending.destination)
                self.selection = self.sidebarSelection(for: pending.destination)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    navigationCoordinator.push(pending.destination, in: targetTab)
                }
            }
        }
        #if os(macOS)
        .onChange(of: navigationCoordinator.auxiliaryWindowRequest?.id) { _ in
            guard let request = navigationCoordinator.auxiliaryWindowRequest else { return }
            openWindow(id: request.destination.windowID)
            navigationCoordinator.consumeAuxiliaryWindowRequest()
            navigationCoordinator.dismissAuxiliaryPresentation()
        }
        #endif
        .if(!usesViewportNowPlayingPresentation) { view in
            view.sheet(isPresented: $showingSheetNowPlaying) {
                NowPlayingSheetView(
                    viewModel: nowPlayingVM,
                    namespace: playerNamespace,
                    animationID: artworkAnimationID,
                    dismissAction: {
                        showingSheetNowPlaying = false
                    }
                )
                .accentColor(deps.settingsManager.accentColor.color)
            }
        }
        // Add account sheet presented at root level so it survives
        // view content recreation on foreground transitions
        .sheet(isPresented: $navigationCoordinator.showingAddAccount) {
            AddPlexAccountView()
            #if os(macOS)
                .frame(width: 720, height: 560)
            #endif
        }
        .onAppear {
            // Register the active NowPlayingViewModel so the external display
            // SceneDelegate (AirPlay screen mirroring) can observe the same instance.
            DependencyContainer.shared.activeNowPlayingViewModel = nowPlayingVM
        }
        .task {
            // Load all sidebar data concurrently so playlists appear
            // immediately rather than waiting for library refresh to finish.
            async let libRefresh: () = libraryVM.refresh()
            async let pinsLoad: () = pinnedVM.loadPinnedItems()
            async let playlistsLoad: () = playlistsVM.loadPlaylists()
            _ = await (libRefresh, pinsLoad, playlistsLoad)
        }
        // Observation-extracted receiver for powerStateMonitor
        .onReceive(powerStateMonitor.$isLowPowerMode) { newValue in
            isLowPowerMode = newValue
        }
        // Keep NavigationCoordinator.selectedTab in sync with sidebar selection
        // so navigate(to:) pushes onto the correct section's NavigationStack
        .onChange(of: selection) { newSelection in
            if let tab = newSelection?.correspondingTab {
                navigationCoordinator.selectedTab = tab
            }
        }
    }

    private var sidebarColumn: some View {
        List(selection: $selection) {
            // Search always appears first
            Label("Search", systemImage: "magnifyingglass")
                .tag(SidebarSelection.library(.search))

            // Library section (non-collapsible)
            Section("Library") {
                Label("Home", systemImage: "house")
                    .tag(SidebarSelection.library(.home))
                Label("Songs", systemImage: "music.note")
                    .tag(SidebarSelection.library(.songs))
                Label("Artists", systemImage: "music.mic")
                    .tag(SidebarSelection.library(.artists))
                Label("Albums", systemImage: "square.stack")
                    .tag(SidebarSelection.library(.albums))
                Label("Genres", systemImage: "guitars")
                    .tag(SidebarSelection.library(.genres))
                Label("Favorites", systemImage: "heart.fill")
                    .tag(SidebarSelection.library(.favorites))
            }

            // Pins section (collapsible — native Section header style)
            if !pinnedVM.resolvedPins.isEmpty {
                collapsibleSidebarSection("Pins", isExpanded: $isPinsExpanded) {
                    ForEach(pinnedVM.resolvedPins) { pin in
                        sidebarPinRow(pin)
                    }
                }
            }

            // Smart Playlists section (collapsible)
            if !cachedSmartPlaylists.isEmpty {
                collapsibleSidebarSection("Smart Playlists", isExpanded: $isSmartPlaylistsExpanded) {
                    ForEach(cachedSmartPlaylists) { playlist in
                        sidebarPlaylistRow(playlist)
                    }
                }
            }

            // Playlists section (collapsible)
            collapsibleSidebarSection("Playlists", isExpanded: $isPlaylistsExpanded) {
                Label("All Playlists", systemImage: "music.note.list")
                    .tag(SidebarSelection.library(.playlists))

                ForEach(cachedRegularPlaylists) { playlist in
                    sidebarPlaylistRow(playlist)
                }
            }

        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        // Downloads + Settings in the sidebar toolbar, pushed to trailing edge
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Spacer()
            }
            ToolbarItem(placement: .automatic) {
                Button { navigationCoordinator.openDownloads() } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .help("Downloads")
            }
            ToolbarItem(placement: .automatic) {
                ProfileToolbarButton()
            }
        }
        .if_available_removeSidebarToggle()
        // Sync cached sidebar playlists from VM publisher. Using @State + .onReceive
        // instead of computed properties ensures updates survive NavigationSplitView
        // re-layouts on macOS that can swallow computed property changes.
        .onReceive(playlistsVM.$playlists) { _ in
            rebuildCachedSidebarPlaylists()
        }
        .onReceive(playlistsVM.$playlistSortOption) { _ in
            rebuildCachedSidebarPlaylists()
        }
        .onReceive(playlistsVM.$filterOptions) { _ in
            rebuildCachedSidebarPlaylists()
        }
        .onReceive(playlistsVM.$isMergeEnabled) { _ in
            rebuildCachedSidebarPlaylists()
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarColumnWidthPreferenceKey.self,
                    value: proxy.size.width
                )
            }
        )
    }

    /// Collapsible sidebar section using native Section(isExpanded:) on iOS 17+/macOS 14+,
    /// falling back to DisclosureGroup on earlier versions. Section(isExpanded:) renders
    /// like Apple Music / Finder — a normal section header with hover-reveal chevron.
    @ViewBuilder
    private func collapsibleSidebarSection<Content: View>(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            Section(title, isExpanded: isExpanded) {
                content()
            }
        } else {
            // Evaluate content eagerly to avoid escaping capture in DisclosureGroup
            let builtContent = content()
            Section {
                DisclosureGroup(isExpanded: isExpanded) {
                    builtContent
                } label: {
                    Text(title)
                }
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
    private func sidebarSelection(for destination: NavigationCoordinator.Destination) -> SidebarSelection {
        switch destination {
        case .artist:
            return .library(.artists)
        case .album:
            return .library(.albums)
        case .playlist(let id, let sourceKey):
            return .playlist(id: id, sourceKey: sourceKey)
        case .mergedPlaylist(let title, let isSmart):
            return .mergedPlaylist(title: title, isSmart: isSmart)
        case .moodTracks:
            return .library(.home)
        case .view(let tab):
            switch tab {
            case .home, .songs, .artists, .albums, .genres, .playlists, .favorites, .search:
                return .library(tab)
            case .downloads, .settings:
                return selection ?? .library(.home)
            }
        }
    }

    /// Map a navigation destination to the tab whose NavigationStack should receive the push
    private func targetTab(for destination: NavigationCoordinator.Destination) -> TabItem {
        switch destination {
        case .artist: return .artists
        case .album: return .albums
        case .playlist, .mergedPlaylist: return .playlists
        case .moodTracks: return .home
        case .view(let tab): return tab
        }
    }

    
    @ViewBuilder
    private var detailView: some View {
        Group {
            switch selection {
            case .library(let tab):
                sidebarNavigationStack(for: tab)
            case .playlist(let id, let sourceKey):
                playlistDetailNavigationStack(playlistID: id, sourceKey: sourceKey)
            case .mergedPlaylist(let title, let isSmart):
                mergedPlaylistDetailNavigationStack(title: title, isSmart: isSmart)
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
                .id("pin-\(id)-\(type)")
            case .none:
                // Fallback when nothing is selected — show Home
                sidebarNavigationStack(for: .home)
            }
        }
        .auroraBackgroundSupport()
    }

    private var detailContainerView: some View {
        detailView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func playlistDetailNavigationStack(playlistID: String, sourceKey: String?) -> some View {
        NavigationStack(path: sidebarPathBinding(for: .playlists)) {
            PlaylistDetailLoader(
                playlistId: playlistID,
                playlistSourceKey: sourceKey,
                nowPlayingVM: nowPlayingVM
            )
            .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                destinationView(for: destination)
                    .auroraBackgroundSupport()
            }
        }
        .id("playlist-detail-\(playlistID)-\(sourceKey ?? "none")")
    }

    @ViewBuilder
    private func mergedPlaylistDetailNavigationStack(title: String, isSmart: Bool) -> some View {
        NavigationStack(path: sidebarPathBinding(for: .playlists)) {
            MergedPlaylistDetailLoader(
                title: title,
                isSmart: isSmart,
                nowPlayingVM: nowPlayingVM
            )
            .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                destinationView(for: destination)
                    .auroraBackgroundSupport()
            }
        }
        .id("merged-playlist-detail-\(title)-\(isSmart)")
    }

    /// Keep the detail column's navigation container shape consistent across sidebar sections.
    /// Mixing typed and untyped NavigationStacks can trip SwiftUI's AnyNavigationPath
    /// comparison logic when the selected section changes.
    @ViewBuilder
    private func sidebarNavigationStack(for tab: TabItem) -> some View {
        NavigationStack(path: sidebarPathBinding(for: tab)) {
            sidebarContentView(for: tab)
        }
    }

    private func sidebarPathBinding(for tab: TabItem) -> Binding<[NavigationCoordinator.Destination]> {
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

    private func detailColumnMiniPlayer(totalSize: CGSize) -> some View {
        let horizontalPadding: CGFloat = 24
        let bottomPadding: CGFloat = 20
        let clampedSidebarWidth = min(max(sidebarColumnWidth, 0), totalSize.width)
        let detailWidth = max(totalSize.width - clampedSidebarWidth, 0)
        let availableWidth = max(detailWidth - (horizontalPadding * 2), 0)
        let miniPlayerWidth = min(540, availableWidth)

        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                MiniPlayer(
                    viewModel: nowPlayingVM,
                    isFloating: true,
                    namespace: playerNamespace,
                    animationID: artworkAnimationID
                ) {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        if usesViewportNowPlayingPresentation {
                            presentViewportNowPlaying(nowPlayingVM)
                        } else {
                            showingSheetNowPlaying = true
                        }
                    }
                }
                .frame(width: miniPlayerWidth)
                .accentColor(deps.settingsManager.accentColor.color)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, horizontalPadding)
            .frame(width: detailWidth, alignment: .center)
            .padding(.leading, clampedSidebarWidth)
            .padding(.bottom, bottomPadding)
        }
        .frame(width: totalSize.width, height: totalSize.height, alignment: .bottomLeading)
        .transition(.identity)
    }

    /// Aurora visualization positioned within the detail column.
    /// Uses the same sidebar-width offset as the mini player so the aurora
    /// covers only the detail area, not the sidebar.
    private func detailColumnAurora(totalSize: CGSize) -> some View {
        let clampedSidebarWidth = min(max(sidebarColumnWidth, 0), totalSize.width)

        return AuroraVisualizationView(
            playbackService: DependencyContainer.shared.playbackService,
            accentColor: settingsManager.accentColor.color,
            isPaused: isShowingNowPlaying,
            isLowPowerMode: isLowPowerMode
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.leading, clampedSidebarWidth)
        .ignoresSafeArea(.all)
        .allowsHitTesting(false)
    }

    /// Sidebar section content with navigation destinations registered for path-based push
    @ViewBuilder
    private func sidebarContentView(for tab: TabItem) -> some View {
        Group {
            if tab == .playlists {
                PlaylistsView(nowPlayingVM: nowPlayingVM, viewModel: playlistsVM)
            } else {
                TabViewFactory.viewContent(for: tab, libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, searchVM: searchVM)
            }
        }
            .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                destinationView(for: destination)
                    .auroraBackgroundSupport()
            }
    }

    /// Sidebar row for a pinned item, showing artwork preview instead of an icon.
    @ViewBuilder
    private func sidebarPinRow(_ pin: ResolvedPin) -> some View {
        let cornerRadius: CGFloat = pin.pinnedItem.type == .artist ? 11 : 4
        switch pin {
        case .artist(let artist, let pinnedItem):
            Label {
                Text(pinnedItem.title)
            } icon: {
                ArtworkView(artist: artist, size: .tiny, cornerRadius: cornerRadius)
                    .frame(width: 22, height: 22)
            }
            .tag(SidebarSelection.pin(id: pinnedItem.id, type: pinnedItem.type))

        case .album(let album, let pinnedItem):
            Label {
                Text(pinnedItem.title)
            } icon: {
                ArtworkView(album: album, size: .tiny, cornerRadius: cornerRadius)
                    .frame(width: 22, height: 22)
            }
            .tag(SidebarSelection.pin(id: pinnedItem.id, type: pinnedItem.type))

        case .playlist(let playlist, let pinnedItem):
            Label {
                Text(pinnedItem.title)
            } icon: {
                ArtworkView(playlist: playlist, size: .tiny, cornerRadius: cornerRadius)
                    .frame(width: 22, height: 22)
            }
            .tag(SidebarSelection.pin(id: pinnedItem.id, type: pinnedItem.type))

        case .mergedPlaylist(let displayPlaylist, let pinnedItems):
            Label {
                Text(displayPlaylist.title)
            } icon: {
                ArtworkView(
                    path: displayPlaylist.primaryPlaylist.compositePath,
                    sourceKey: displayPlaylist.primaryPlaylist.sourceCompositeKey,
                    ratingKey: displayPlaylist.primaryPlaylist.id,
                    size: .tiny,
                    cornerRadius: 4
                )
                .frame(width: 22, height: 22)
            }
            .tag(SidebarSelection.pin(id: pinnedItems[0].id, type: pinnedItems[0].type))
        }
    }

    /// Sidebar row for a playlist item, showing artwork preview instead of an icon.
    @ViewBuilder
    private func sidebarPlaylistRow(_ playlist: SidebarPlaylistItem) -> some View {
        let artworkLabel = Label {
            Text(playlist.title)
        } icon: {
            ArtworkView(
                path: playlist.compositePath,
                sourceKey: playlist.sourceKey,
                ratingKey: playlist.playlistID,
                size: .tiny,
                cornerRadius: 4
            )
            .frame(width: 22, height: 22)
        }

        if playlist.isMerged {
            artworkLabel
                .tag(SidebarSelection.mergedPlaylist(title: playlist.title, isSmart: playlist.isSmart))
        } else {
            artworkLabel
                .tag(SidebarSelection.playlist(id: playlist.playlistID, sourceKey: playlist.sourceKey))
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
        case .mergedPlaylist(let title, let isSmart):
            MergedPlaylistDetailLoader(title: title, isSmart: isSmart, nowPlayingVM: nowPlayingVM)
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

public enum SidebarSelection: Hashable {
    case library(TabItem)
    case playlist(id: String, sourceKey: String?)
    case mergedPlaylist(title: String, isSmart: Bool)
    case pin(id: String, type: PinnedItemType)

    /// Map sidebar section to the corresponding TabItem for NavigationCoordinator sync.
    /// Returns nil for pinned items which don't map to a standard tab.
    var correspondingTab: TabItem? {
        switch self {
        case .library(let tab):
            return tab
        case .playlist, .mergedPlaylist:
            return .playlists
        case .pin:
            return nil
        }
    }
}

// MARK: - macOS Sidebar Collapse Prevention


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

    /// Remove the sidebar toggle button. Requires iOS 17+/macOS 14+; no-op on earlier.
    @ViewBuilder
    func if_available_removeSidebarToggle() -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}
