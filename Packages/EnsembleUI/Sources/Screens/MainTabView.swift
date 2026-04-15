import EnsembleCore
import Combine
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
    private let nowPlayingVM: NowPlayingViewModel
    @StateObject private var searchVM: SearchViewModel
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    // Observation-extracted: networkMonitor publishes on every network state change,
    // which would invalidate the entire root view. We only need networkState, so we
    // listen to just that property and store it in @State.
    private let networkMonitor = DependencyContainer.shared.networkMonitor
    private let powerStateMonitor = DependencyContainer.shared.powerStateMonitor
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @Environment(\.dependencies) private var deps
    @Environment(\.isViewportNowPlayingPresented) private var isViewportNowPlayingPresented
    @State private var didSetInitialTab = false
    @State private var isImmersiveMode = false
    @State private var immersiveModeClearWorkItem: DispatchWorkItem?
    // Extracted observation state — avoids full root invalidation from singleton publishers
    @State private var networkState: NetworkState = DependencyContainer.shared.networkMonitor.networkState
    @State private var isLowPowerMode: Bool = DependencyContainer.shared.powerStateMonitor.isLowPowerMode
    #if os(iOS)
    @State private var keyboardVisible = false
    #endif

    // Get the tabs to show in the bar (limit to 4, then More)
    private var barTabs: [TabItem] {
        Array(settingsManager.enabledTabs.prefix(4))
    }

    @MainActor
    public init(nowPlayingVM: NowPlayingViewModel) {
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self.nowPlayingVM = nowPlayingVM
        self._searchVM = StateObject(wrappedValue: DependencyContainer.shared.makeSearchViewModel())
    }

    private var isKeyboardVisible: Bool {
        #if os(iOS)
        return keyboardVisible
        #else
        return false
        #endif
    }

    private var showsPhoneAuroraOverlay: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var isShowingNowPlaying: Bool {
        isViewportNowPlayingPresented
    }

    private var profileSheetBinding: Binding<Bool> {
        Binding(
            get: { navigationCoordinator.activeAuxiliaryPresentation == .profile },
            set: { isPresented in
                guard !isPresented,
                      navigationCoordinator.activeAuxiliaryPresentation == .profile else { return }
                navigationCoordinator.dismissAuxiliaryPresentation()
            }
        )
    }

    private var downloadsAuxiliaryBinding: Binding<NavigationCoordinator.AuxiliaryPresentation?> {
        Binding(
            get: {
                navigationCoordinator.activeAuxiliaryPresentation == .downloads ? .downloads : nil
            },
            set: { destination in
                guard destination == nil,
                      navigationCoordinator.activeAuxiliaryPresentation == .downloads else { return }
                navigationCoordinator.dismissAuxiliaryPresentation()
            }
        )
    }

    private var isRootChromeSuppressed: Bool {
        isImmersiveMode || navigationCoordinator.isKeyboardEditorPresented
    }

    private func shouldForceStageFlowImmersive(for size: CGSize) -> Bool {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        if #available(iOS 16.0, *) {
            return false
        }
        guard size.width > size.height else { return false }

        switch navigationCoordinator.selectedTab {
        case .albums, .songs, .playlists:
            return true
        default:
            return false
        }
        #else
        return false
        #endif
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
            let stageFlowFallbackImmersive = shouldForceStageFlowImmersive(for: geometry.size)
            let rootChromeSuppressed = isRootChromeSuppressed || stageFlowFallbackImmersive

            let rootView = VStack(spacing: 0) {
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
                    isHidden: rootChromeSuppressed
                )
                .applyTabViewStyle(sidebarAdaptable: useSidebarAdaptable)
            }
                // iOS 15: set additionalSafeAreaInsets on each tab's navigation controller
                // so content scrolls behind the tab bar with proper mini player clearance.
                // The 70pt covers the mini player height + spacing above the tab bar.
                .miniPlayerContainerInset(
                    TrackListLayoutMetrics.miniPlayerContainerInset,
                    isVisible: !isShowingNowPlaying && !isKeyboardVisible && !rootChromeSuppressed && !navigationCoordinator.isKeyboardEditorPresented
                )
                .zIndex(0)
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
            #if os(iOS)
            .onReceive(Publishers.keyboardHeight.map { $0 > 0 }.removeDuplicates()) { newValue in
                // Keep the presenting shell stable while an auxiliary sheet or
                // keyboard-heavy editor owns the keyboard-driven layout changes.
                if navigationCoordinator.activeAuxiliaryPresentation == nil &&
                    !navigationCoordinator.isKeyboardEditorPresented {
                    keyboardVisible = newValue
                } else if !newValue {
                    keyboardVisible = false
                }
            }
            .onChange(of: navigationCoordinator.activeAuxiliaryPresentation != nil || navigationCoordinator.isKeyboardEditorPresented) { isPresented in
                if isPresented {
                    keyboardVisible = false
                }
            }
            #endif
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
            #if os(iOS)
            .sheet(isPresented: profileSheetBinding, onDismiss: {
                navigationCoordinator.dismissAuxiliaryPresentation()
            }) {
                ProfilePresentationContainer()
                    .accentColor(settingsManager.accentColor.color)
            }
            .phoneSafeAuxiliaryPresentation(item: downloadsAuxiliaryBinding, onDismiss: {
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
                    .background(
                        RootChromeFrameRegistrationView(
                            bottomPadding: miniPlayerBottomLift,
                            showsMiniPlayer: !isShowingNowPlaying &&
                                !isKeyboardVisible &&
                                !rootChromeSuppressed &&
                                !navigationCoordinator.isKeyboardEditorPresented,
                            priority: 0
                        )
                    )
                    .overlay(alignment: .top) {
                        if !rootChromeSuppressed {
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
                    immersiveModeClearWorkItem?.cancel()
                    if isHidden {
                        if isImmersiveMode != true {
                            isImmersiveMode = true
                        }
                    } else {
                        let clearWorkItem = DispatchWorkItem {
                            if isImmersiveMode != false {
                                isImmersiveMode = false
                            }
                        }
                        immersiveModeClearWorkItem = clearWorkItem
                        // iOS 15 posts transient "false" signals during landscape
                        // geometry churn; delay clearing so root chrome doesn't flash.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: clearWorkItem)
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
                    .environment(\.showsProfileToolbar, shouldShowProfileButton(for: tab, isMoreRoot: isMoreRoot))
                    .auroraBackgroundSupport()
                    .background(
                        NestedNavigationLink(
                            path: pathForTab(tab),
                            tab: tab,
                            navigationCoordinator: navigationCoordinator,
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
            if showsPhoneAuroraOverlay &&
                settingsManager.auroraVisualizationEnabled &&
                !isShowingNowPlaying &&
                !isRootChromeSuppressed &&
                !navigationCoordinator.isKeyboardEditorPresented &&
                navigationCoordinator.activeAuxiliaryPresentation == nil {
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
        .environment(\.showsProfileToolbar, shouldShowProfileButton(for: tab, isMoreRoot: isMoreRoot))
    }

    @ViewBuilder
    private func destinationView(for destination: NavigationCoordinator.Destination) -> some View {
        destinationContentView(for: destination)
            .environment(\.showsProfileToolbar, false)
    }

    @ViewBuilder
    private func destinationContentView(for destination: NavigationCoordinator.Destination) -> some View {
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

    private func shouldShowProfileButton(for tab: TabItem, isMoreRoot: Bool) -> Bool {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        guard pathForTab(tab).isEmpty else { return false }
        return isMoreRoot || barTabs.contains(tab)
        #else
        return false
        #endif
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
    let navigationCoordinator: NavigationCoordinator
    let destinationBuilder: (NavigationCoordinator.Destination) -> DestinationView
    
    var body: some View {
        if let first = path.first {
            NavigationLink(
                isActive: Binding(
                    get: { !path.isEmpty },
                    set: { if !$0 { navigationCoordinator.popToRoot(tab: tab) } }
                ),
                destination: {
                    destinationBuilder(first)
                        .background(
                            NestedNavigationLink(
                                path: Array(path.dropFirst()),
                                tab: tab,
                                navigationCoordinator: navigationCoordinator,
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

    /// Sheet payload for sidebar album actions that need playlist selection.
    private struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }

    @StateObject private var libraryVM: LibraryViewModel
    private let nowPlayingVM: NowPlayingViewModel
    @StateObject private var searchVM: SearchViewModel
    @StateObject private var pinnedVM: PinnedViewModel
    @StateObject private var playlistsVM: PlaylistViewModel
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    private let pinManager = DependencyContainer.shared.pinManager
    @Environment(\.dependencies) private var deps
    @Environment(\.isViewportNowPlayingPresented) private var isViewportNowPlayingPresented
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    private enum CompactColumnPreference: Int {
        case sidebar
        case detail
    }

    @State private var selection: SidebarSelection? = .library(.home)
    @State private var pinnedDetailPath: [NavigationCoordinator.Destination] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var compactColumnPreference: CompactColumnPreference = .detail
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    @State private var playlistForEditSheet: Playlist?
    @State private var playlistPendingRename: Playlist?
    @State private var mergedPlaylistPendingRename: DisplayPlaylist?
    @State private var playlistPendingDelete: Playlist?
    @State private var mergedPlaylistPendingDelete: DisplayPlaylist?
    @SceneStorage("sidebarPinsExpanded") private var isPinsExpanded = true
    @SceneStorage("sidebarSmartPlaylistsExpanded") private var isSmartPlaylistsExpanded = true
    @SceneStorage("sidebarPlaylistsExpanded") private var isPlaylistsExpanded = true

    private var profileSheetBinding: Binding<Bool> {
        Binding(
            get: { navigationCoordinator.activeAuxiliaryPresentation == .profile },
            set: { isPresented in
                guard !isPresented,
                      navigationCoordinator.activeAuxiliaryPresentation == .profile else { return }
                navigationCoordinator.dismissAuxiliaryPresentation()
            }
        )
    }

    private var downloadsAuxiliaryBinding: Binding<NavigationCoordinator.AuxiliaryPresentation?> {
        Binding(
            get: {
                navigationCoordinator.activeAuxiliaryPresentation == .downloads ? .downloads : nil
            },
            set: { destination in
                guard destination == nil,
                      navigationCoordinator.activeAuxiliaryPresentation == .downloads else { return }
                navigationCoordinator.dismissAuxiliaryPresentation()
            }
        )
    }

    // Cached sidebar playlist items driven by .onReceive — avoids computed property
    // re-evaluation issues on macOS where NavigationSplitView can swallow updates.
    @State private var cachedSmartPlaylists: [SidebarPlaylistItem] = []
    @State private var cachedRegularPlaylists: [SidebarPlaylistItem] = []

    @MainActor
    public init(nowPlayingVM: NowPlayingViewModel) {
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self.nowPlayingVM = nowPlayingVM
        self._searchVM = StateObject(wrappedValue: DependencyContainer.shared.makeSearchViewModel())
        self._pinnedVM = StateObject(wrappedValue: DependencyContainer.shared.makePinnedViewModel())
        self._playlistsVM = StateObject(wrappedValue: DependencyContainer.shared.makePlaylistViewModel())
    }

    private var isShowingNowPlaying: Bool {
        isViewportNowPlayingPresented
    }

    private var isShowingCompactSidebarRoot: Bool {
        guard compactColumnPreference == .sidebar else {
            return false
        }

        guard let selection else {
            return true
        }

        switch selection {
        case .library(let tab):
            return sidebarPath(for: tab).isEmpty
        case .playlist, .mergedPlaylist, .pin:
            return false
        }
    }

    private func sidebarPath(for tab: TabItem) -> [NavigationCoordinator.Destination] {
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

    private func handlePinnedSelectionRemoval(ids: Set<String>, fallback: SidebarSelection) {
        guard case .pin(let selectedID, _) = selection, ids.contains(selectedID) else { return }
        selection = fallback
    }

    private func navigateFromPinnedMenu(to destination: NavigationCoordinator.Destination) {
        selection = sidebarSelection(for: destination)
        DispatchQueue.main.async {
            navigationCoordinator.push(destination, in: targetTab(for: destination))
        }
    }

    private func startPinnedPlaylistDelete(for playlist: Playlist) {
        guard !playlist.isSmart else { return }

        let deletingToast = ToastPayload(
            style: .info,
            iconSystemName: "trash",
            title: "Deleting \(playlist.title)...",
            isPersistent: true,
            dedupeKey: "sidebar-playlist-delete-pending-\(playlist.id)",
            showsActivityIndicator: true
        )
        deps.toastCenter.show(deletingToast)

        Task {
            let didDelete = await playlistsVM.deletePlaylist(playlist)
            deps.toastCenter.dismiss(id: deletingToast.id)

            if didDelete {
                handlePinnedSelectionRemoval(ids: [playlist.id], fallback: .library(.playlists))
                pinManager.unpin(id: playlist.id)
                deps.toastCenter.show(
                    ToastPayload(
                        style: .success,
                        iconSystemName: "checkmark.circle.fill",
                        title: "Deleted \(playlist.title)",
                        dedupeKey: "sidebar-playlist-delete-success-\(playlist.id)"
                    )
                )
            } else {
                deps.toastCenter.show(
                    ToastPayload(
                        style: .error,
                        iconSystemName: "xmark.octagon.fill",
                        title: "Could not delete \(playlist.title)",
                        message: playlistsVM.error ?? "Try again later.",
                        dedupeKey: "sidebar-playlist-delete-error-\(playlist.id)"
                    )
                )
            }
        }
    }

    private func renamePinnedPlaylist(_ playlist: Playlist, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let renamingToast = ToastPayload(
            style: .info,
            iconSystemName: "pencil",
            title: "Renaming \(playlist.title)...",
            isPersistent: true,
            dedupeKey: "sidebar-playlist-rename-pending-\(playlist.id)",
            showsActivityIndicator: true
        )
        playlistsVM.applyOptimisticRename(for: playlist, newTitle: trimmed)
        deps.toastCenter.show(renamingToast)

        Task {
            do {
                let outcome = try await deps.mutationCoordinator.renamePlaylist(playlist, to: trimmed)
                if outcome == .completed {
                    await playlistsVM.awaitRenamedPlaylistMaterialization(for: playlist.id, expectedTitle: trimmed)
                    pinManager.updateTitle(id: playlist.id, title: trimmed)
                }

                deps.toastCenter.dismiss(id: renamingToast.id)
                deps.toastCenter.show(
                    ToastPayload(
                        style: outcome == .queued ? .info : .success,
                        iconSystemName: outcome == .queued ? "clock.arrow.circlepath" : "pencil.circle.fill",
                        title: outcome == .queued ? "Rename queued — will sync when online" : "Renamed playlist",
                        dedupeKey: "sidebar-playlist-rename-success-\(playlist.id)"
                    )
                )
            } catch {
                playlistsVM.clearOptimisticRename(for: playlist.id)
                await playlistsVM.loadPlaylists()
                deps.toastCenter.dismiss(id: renamingToast.id)
                deps.toastCenter.show(
                    ToastPayload(
                        style: .error,
                        iconSystemName: "xmark.octagon.fill",
                        title: "Could not rename playlist",
                        message: error.localizedDescription,
                        dedupeKey: "sidebar-playlist-rename-error-\(playlist.id)"
                    )
                )
            }
        }
    }

    public var body: some View {
        splitNavigationView
        #if os(iOS)
        .sheet(isPresented: profileSheetBinding, onDismiss: {
            navigationCoordinator.dismissAuxiliaryPresentation()
        }) {
            ProfilePresentationContainer()
                .accentColor(settingsManager.accentColor.color)
        }
        .phoneSafeAuxiliaryPresentation(item: downloadsAuxiliaryBinding, onDismiss: {
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
        // Add account sheet presented at root level so it survives
        // view content recreation on foreground transitions
        .sheet(isPresented: $navigationCoordinator.showingAddAccount) {
            AddPlexAccountView()
            #if os(macOS)
                .frame(width: 720, height: 560)
            #endif
        }
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(nowPlayingVM: nowPlayingVM, tracks: payload.tracks, title: payload.title)
        }
        .sheet(item: $playlistForEditSheet) { playlist in
            NavigationView {
                PlaylistDetailView(
                    playlist: playlist,
                    nowPlayingVM: nowPlayingVM,
                    startInEditMode: true
                )
            }
        }
        .keyboardSafeEditorPresentation(item: $playlistPendingRename) { playlist in
            TextInputView(
                title: "Rename Playlist",
                placeholder: "Playlist name",
                initialText: playlist.title,
                actionTitle: "Save"
            ) { name in
                renamePinnedPlaylist(playlist, to: name)
            }
        }
        .keyboardSafeEditorPresentation(item: $mergedPlaylistPendingRename) { displayPlaylist in
            TextInputView(
                title: "Rename Playlist",
                message: "This will rename on \(displayPlaylist.playlists.count) server\(displayPlaylist.playlists.count == 1 ? "" : "s").",
                placeholder: "Playlist name",
                initialText: displayPlaylist.title,
                actionTitle: "Save"
            ) { name in
                playlistsVM.applyOptimisticRenameForMerged(displayPlaylist, newTitle: name)
                for playlist in displayPlaylist.playlists {
                    renamePinnedPlaylist(playlist, to: name)
                }
            }
        }
        .alert("Delete Playlist?", isPresented: Binding(
            get: { playlistPendingDelete != nil },
            set: { if !$0 { playlistPendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                playlistPendingDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard let playlist = playlistPendingDelete else { return }
                playlistPendingDelete = nil
                startPinnedPlaylistDelete(for: playlist)
            }
        } message: {
            Text("This will permanently delete \"\(playlistPendingDelete?.title ?? "this playlist")\" from Plex.")
        }
        .alert("Delete Merged Playlist?", isPresented: Binding(
            get: { mergedPlaylistPendingDelete != nil },
            set: { if !$0 { mergedPlaylistPendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                mergedPlaylistPendingDelete = nil
            }
            Button("Delete All", role: .destructive) {
                guard let displayPlaylist = mergedPlaylistPendingDelete else { return }
                mergedPlaylistPendingDelete = nil
                handlePinnedSelectionRemoval(
                    ids: Set(displayPlaylist.playlists.map(\.id)),
                    fallback: .library(.playlists)
                )
                for playlist in displayPlaylist.playlists {
                    startPinnedPlaylistDelete(for: playlist)
                }
            }
        } message: {
            let count = mergedPlaylistPendingDelete?.playlists.count ?? 0
            Text("This will permanently delete \"\(mergedPlaylistPendingDelete?.title ?? "")\" from \(count) server\(count == 1 ? "" : "s").")
        }
        .task {
            // Load all sidebar data concurrently so playlists appear
            // immediately rather than waiting for library refresh to finish.
            async let libRefresh: () = libraryVM.refresh()
            async let pinsLoad: () = pinnedVM.loadPinnedItems()
            async let playlistsLoad: () = playlistsVM.loadPlaylists()
            _ = await (libRefresh, pinsLoad, playlistsLoad)
        }
        // Keep NavigationCoordinator.selectedTab in sync with sidebar selection
        // so navigate(to:) pushes onto the correct section's NavigationStack
        .onChange(of: selection) { newSelection in
            if let tab = newSelection?.correspondingTab {
                navigationCoordinator.selectedTab = tab
            }
            #if os(iOS)
            if #available(iOS 17.0, *), newSelection != nil {
                compactColumnPreference = .detail
            }
            #endif
            pinnedDetailPath.removeAll()
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
                    .onMove { source, destination in
                        pinnedVM.move(fromOffsets: source, toOffset: destination)
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
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(
                    height: isShowingNowPlaying
                        ? 0
                        : TrackListLayoutMetrics.miniPlayerContainerInset
                )
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 260, max: 260)
        .toolbar {
            ToolbarItem { Spacer() }
            ToolbarItemGroup(placement: .primaryActionIfAvailable) {
                Button { navigationCoordinator.openDownloads() } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .help("Downloads")
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
                pinnedDetailNavigationStack(id: id, type: type)
            case .none:
                // Fallback when nothing is selected — show Home
                sidebarNavigationStack(for: .home)
            }
        }
        .auroraBackgroundSupport()
    }

    private var detailContainerView: some View {
        detailView
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func playlistDetailNavigationStack(playlistID: String, sourceKey: String?) -> some View {
        detailColumnNavigationHost {
            NavigationStack(path: sidebarPathBinding(for: .playlists)) {
                detailChromeRegistrationHost {
                    PlaylistDetailLoader(
                        playlistId: playlistID,
                        playlistSourceKey: sourceKey,
                        nowPlayingVM: nowPlayingVM
                    )
                }
                .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                    detailChromeRegistrationHost(
                        priority: max(sidebarPath(for: .playlists).count, 1)
                    ) {
                        destinationView(for: destination)
                    }
                }
            }
        }
        .id("playlist-detail-\(playlistID)-\(sourceKey ?? "none")")
    }

    @ViewBuilder
    private func mergedPlaylistDetailNavigationStack(title: String, isSmart: Bool) -> some View {
        detailColumnNavigationHost {
            NavigationStack(path: sidebarPathBinding(for: .playlists)) {
                detailChromeRegistrationHost {
                    MergedPlaylistDetailLoader(
                        title: title,
                        isSmart: isSmart,
                        nowPlayingVM: nowPlayingVM
                    )
                }
                .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                    detailChromeRegistrationHost(
                        priority: max(sidebarPath(for: .playlists).count, 1)
                    ) {
                        destinationView(for: destination)
                    }
                }
            }
        }
        .id("merged-playlist-detail-\(title)-\(isSmart)")
    }

    /// Keep the detail column's navigation container shape consistent across sidebar sections.
    /// Mixing typed and untyped NavigationStacks can trip SwiftUI's AnyNavigationPath
    /// comparison logic when the selected section changes.
    @ViewBuilder
    private func sidebarNavigationStack(for tab: TabItem) -> some View {
        detailColumnNavigationHost {
            NavigationStack(path: sidebarPathBinding(for: tab)) {
                detailChromeRegistrationHost {
                    sidebarContentView(for: tab)
                }
            }
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

    @ViewBuilder
    private func pinnedDetailNavigationStack(id: String, type: PinnedItemType) -> some View {
        detailColumnNavigationHost {
            NavigationStack(path: $pinnedDetailPath) {
                detailChromeRegistrationHost {
                    pinnedDetailRootView(id: id, type: type)
                }
                .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                    detailChromeRegistrationHost(
                        priority: max(pinnedDetailPath.count, 1)
                    ) {
                        destinationView(for: destination)
                    }
                }
            }
        }
        .id("pin-\(id)-\(type)")
    }

    @ViewBuilder
    private func pinnedDetailRootView(id: String, type: PinnedItemType) -> some View {
        switch type {
        case .album:
            AlbumDetailLoader(albumId: id, nowPlayingVM: nowPlayingVM)
        case .artist:
            ArtistDetailLoader(artistId: id, nowPlayingVM: nowPlayingVM)
        case .playlist:
            PlaylistDetailLoader(playlistId: id, playlistSourceKey: nil, nowPlayingVM: nowPlayingVM)
        }
    }

    @ViewBuilder
    private func detailColumnNavigationHost<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Register the currently visible detail/root screen with the root chrome layer.
    /// This keeps the shared mini player anchored to the live content frame even
    /// while NavigationSplitView collapses or expands around a pushed destination.
    @ViewBuilder
    private func detailChromeRegistrationHost<Content: View>(
        priority: Int = 0,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let registeredContent = content()
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                registeredContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .background(
                RootChromeFrameRegistrationView(
                    bottomPadding: min(max(proxy.safeAreaInsets.bottom + 12, 20), 32),
                    showsMiniPlayer: !isShowingNowPlaying,
                    priority: priority
                )
            )
        }
    }

    @ViewBuilder
    private var splitNavigationView: some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            splitNavigationViewWithCompactColumn
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarColumn
            } detail: {
                detailContainerView
                    .macEditorToolbarRoleIfAvailable()
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    @available(iOS 17.0, macOS 14.0, *)
    @ViewBuilder
    private var splitNavigationViewWithCompactColumn: some View {
        #if os(iOS)
        let preferredCompactColumn = Binding<NavigationSplitViewColumn>(
            get: {
                isShowingCompactSidebarRoot ? .sidebar : .detail
            },
            set: { newValue in
                compactColumnPreference = newValue == .sidebar ? .sidebar : .detail
            }
        )
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: preferredCompactColumn
        ) {
            sidebarColumn
        } detail: {
            detailContainerView
                .macEditorToolbarRoleIfAvailable()
        }
        .navigationSplitViewStyle(.balanced)
        #else
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
        } detail: {
            detailContainerView
                .macEditorToolbarRoleIfAvailable()
        }
        .navigationSplitViewStyle(.balanced)
        #endif
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
            detailChromeRegistrationHost(
                priority: max(sidebarPath(for: tab).count, 1)
            ) {
                destinationView(for: destination)
            }
        }
    }

    /// Sidebar row for a pinned item, showing artwork preview instead of an icon.
    @ViewBuilder
    private func sidebarPinRow(_ pin: ResolvedPin) -> some View {
        let artworkDimension: CGFloat = 22
        let cornerRadius: CGFloat = pin.pinnedItem.type == .artist
            ? ArtworkCornerRadius.circle(for: artworkDimension)
            : ArtworkCornerRadius.square(for: artworkDimension)
        switch pin {
        case .artist(let artist, let pinnedItem):
            Label {
                Text(pinnedItem.title)
            } icon: {
                ArtworkView(artist: artist, size: .tiny, cornerRadius: cornerRadius, isResponsive: true)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .tag(SidebarSelection.pin(id: pinnedItem.id, type: pinnedItem.type))
            .contextMenu {
                ArtistActionsContextMenu(
                    artist: artist,
                    nowPlayingVM: nowPlayingVM,
                    toastNamespace: "sidebar-artist-menu",
                    customPinAction: { isPinned in
                        if isPinned {
                            handlePinnedSelectionRemoval(ids: [pinnedItem.id], fallback: .library(.artists))
                            pinManager.unpin(id: pinnedItem.id)
                        } else {
                            pinManager.pin(
                                id: artist.id,
                                sourceKey: artist.sourceCompositeKey ?? "",
                                type: .artist,
                                title: artist.name
                            )
                        }
                    }
                )
            }

        case .album(let album, let pinnedItem):
            Label {
                Text(pinnedItem.title)
            } icon: {
                ArtworkView(album: album, size: .tiny, cornerRadius: cornerRadius, isResponsive: true)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .tag(SidebarSelection.pin(id: pinnedItem.id, type: pinnedItem.type))
            .contextMenu {
                AlbumActionsContextMenu(
                    album: album,
                    nowPlayingVM: nowPlayingVM,
                    presentPlaylistPicker: { tracks, title in
                        playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: title)
                    },
                    toastNamespace: "sidebar-album-menu",
                    navigateToArtist: { artistID in
                        navigateFromPinnedMenu(to: .artist(id: artistID))
                    },
                    customPinAction: { isPinned in
                        if isPinned {
                            handlePinnedSelectionRemoval(ids: [pinnedItem.id], fallback: .library(.albums))
                            pinManager.unpin(id: pinnedItem.id)
                        } else {
                            pinManager.pin(
                                id: album.id,
                                sourceKey: album.sourceCompositeKey ?? "",
                                type: .album,
                                title: album.title
                            )
                        }
                    }
                )
            }

        case .playlist(let playlist, let pinnedItem):
            Label {
                Text(pinnedItem.title)
            } icon: {
                ArtworkView(playlist: playlist, size: .tiny, cornerRadius: cornerRadius, isResponsive: true)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .tag(SidebarSelection.pin(id: pinnedItem.id, type: pinnedItem.type))
            .contextMenu {
                PlaylistActionsContextMenu(
                    playlist: playlist,
                    nowPlayingVM: nowPlayingVM,
                    toastNamespace: "sidebar-playlist-menu",
                    onRename: {
                        playlistPendingRename = playlist
                    },
                    onEdit: {
                        playlistForEditSheet = playlist
                    },
                    onDelete: {
                        playlistPendingDelete = playlist
                    },
                    customPinAction: { isPinned in
                        if isPinned {
                            handlePinnedSelectionRemoval(ids: [pinnedItem.id], fallback: .library(.playlists))
                            pinManager.unpin(id: pinnedItem.id)
                        } else {
                            pinManager.pin(
                                id: playlist.id,
                                sourceKey: playlist.sourceCompositeKey ?? "",
                                type: .playlist,
                                title: playlist.title
                            )
                        }
                    }
                )
            }

        case .mergedPlaylist(let displayPlaylist, let pinnedItems):
            Label {
                Text(displayPlaylist.title)
            } icon: {
                ArtworkView(
                    path: displayPlaylist.primaryPlaylist.compositePath,
                    sourceKey: displayPlaylist.primaryPlaylist.sourceCompositeKey,
                    ratingKey: displayPlaylist.primaryPlaylist.id,
                    size: .tiny,
                    cornerRadius: ArtworkCornerRadius.square(for: artworkDimension),
                    isResponsive: true
                )
                .frame(width: artworkDimension, height: artworkDimension)
                .clipShape(RoundedRectangle(cornerRadius: ArtworkCornerRadius.square(for: artworkDimension), style: .continuous))
            }
            .tag(SidebarSelection.pin(id: pinnedItems[0].id, type: pinnedItems[0].type))
            .contextMenu {
                MergedPlaylistActionsContextMenu(
                    displayPlaylist: displayPlaylist,
                    nowPlayingVM: nowPlayingVM,
                    toastNamespace: "sidebar-merged-playlist-menu",
                    onRename: {
                        mergedPlaylistPendingRename = displayPlaylist
                    },
                    onDelete: {
                        mergedPlaylistPendingDelete = displayPlaylist
                    }
                )

                Divider()

                Button(role: .destructive) {
                    handlePinnedSelectionRemoval(
                        ids: Set(pinnedItems.map(\.id)),
                        fallback: .library(.playlists)
                    )
                    pinManager.unpinAll(ids: Set(pinnedItems.map(\.id)))
                } label: {
                    Label("Unpin All", systemImage: "pin.slash")
                }
            }
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
                cornerRadius: ArtworkCornerRadius.square(for: 22),
                isResponsive: true
            )
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: ArtworkCornerRadius.square(for: 22), style: .continuous))
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
