import EnsembleCore
import Combine
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Main tab bar view for iPhone (5-tab classic iOS style)
public struct MainTabView: View {
    @StateObject private var libraryVM: LibraryViewModel
    private let nowPlayingVM: NowPlayingViewModel
    @StateObject private var homeVM: HomeViewModel
    @StateObject private var searchVM: SearchViewModel
    @StateObject private var pinnedVM: PinnedViewModel
    private let settingsManager = DependencyContainer.shared.settingsManager
    // Observation-extracted: networkMonitor publishes on every network state change,
    // which would invalidate the entire root view. We only need networkState, so we
    // listen to just that property and store it in @State.
    private let networkMonitor = DependencyContainer.shared.networkMonitor
    private let powerStateMonitor = DependencyContainer.shared.powerStateMonitor
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @Environment(\.dependencies) private var deps
    @Environment(\.isViewportNowPlayingPresented) private var isViewportNowPlayingPresented
    @Environment(\.isSoftwareKeyboardVisible) private var isSoftwareKeyboardVisible
    @State private var didSetInitialTab = false
    // Extracted observation state — avoids full root invalidation from singleton publishers
    @State private var networkState: NetworkState = DependencyContainer.shared.networkMonitor.networkState
    @State private var isLowPowerMode: Bool = DependencyContainer.shared.powerStateMonitor.isLowPowerMode
    @State private var enabledTabs: [TabItem] = DependencyContainer.shared.settingsManager.enabledTabs
    @State private var accentColor: AppAccentColor = DependencyContainer.shared.settingsManager.accentColor
    @State private var auroraVisualizationEnabled: Bool = DependencyContainer.shared.settingsManager.auroraVisualizationEnabled
    // Get the tabs to show in the bar (limit to 4, then More)
    private var barTabs: [TabItem] {
        Array(enabledTabs.prefix(4))
    }

    private var selectedRootTab: TabItem {
        if !didSetInitialTab {
            return MainTabInitialSelectionPolicy.initialRootTab(
                selectedTab: navigationCoordinator.selectedTab,
                selectedPath: navigationCoordinator.pathSnapshot(for: navigationCoordinator.selectedTab),
                barTabs: barTabs
            )
        }

        return MainTabInitialSelectionPolicy.rootTab(
            selectedTab: navigationCoordinator.selectedTab,
            barTabs: barTabs
        )
    }

    @MainActor
    public init(nowPlayingVM: NowPlayingViewModel) {
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self.nowPlayingVM = nowPlayingVM
        self._homeVM = StateObject(wrappedValue: DependencyContainer.shared.makeHomeViewModel())
        self._searchVM = StateObject(wrappedValue: DependencyContainer.shared.makeSearchViewModel())
        self._pinnedVM = StateObject(wrappedValue: DependencyContainer.shared.makePinnedViewModel())
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

    private var activeStageFlowRootTab: TabItem? {
        #if os(iOS)
        return MainTabStageFlowPolicy.activeRootTab(
            selectedRootTab: selectedRootTab,
            morePath: navigationCoordinator.pathSnapshot(for: .settings),
            isPhone: UIDevice.current.userInterfaceIdiom == .phone
        )
        #else
        return nil
        #endif
    }

    private var selectedTabSupportsStageFlow: Bool {
        activeStageFlowRootTab != nil
    }

    private func isStageFlowActive(for size: CGSize, activeTab: TabItem?) -> Bool {
        #if os(iOS)
        return activeTab != nil && size.width > size.height
        #else
        return false
        #endif
    }

    public var body: some View {
        GeometryReader { geometry in
            let miniPlayerBottomLift = TrackListLayoutMetrics.rootMiniPlayerBottomLift(
                safeAreaBottom: geometry.safeAreaInsets.bottom
            )
            let activeStageFlowRootTab = activeStageFlowRootTab
            let rootStageFlowActive = isStageFlowActive(for: geometry.size, activeTab: activeStageFlowRootTab)
            let rootChromeSuppressed = rootStageFlowActive
            let miniPlayerSuppressed = rootChromeSuppressed || isSoftwareKeyboardVisible

            let rootView = VStack(spacing: EnsembleDesign.Spacing.none) {
                tabBarVisibility(
                    TabView(selection: tabBinding) {
                        ForEach(barTabs) { tab in
                            tabRootView(
                                for: tab,
                                rootChromeSuppressed: rootChromeSuppressed,
                                isStageFlowActive: rootStageFlowActive && activeStageFlowRootTab == tab
                            )
                                .tag(tab)
                                .tabItem {
                                    Label(tab.displayTitle, systemImage: tab.designSystemImage)
                                }
                        }

                        tabRootView(
                            for: .settings,
                            isMoreRoot: true,
                            rootChromeSuppressed: rootChromeSuppressed,
                            isStageFlowActive: rootStageFlowActive && selectedRootTab == .settings
                        )
                            .tag(TabItem.settings)
                            .tabItem {
                                Label("More", systemImage: EnsembleDesign.Icon.more)
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
                    isVisible: !isShowingNowPlaying && !miniPlayerSuppressed
                )
                .zIndex(0)
            .task {
                // Sync selectedTab with the actual first visible tab on launch.
                // selectedTab defaults to .home, but the user may have reordered
                // tabs so .home isn't in the bar — causing navigateFromNowPlaying
                // to target the wrong tab until a manual tab switch.
                if !didSetInitialTab {
                    syncVisibleTabs()
                    reconcileInitialTabSelection()
                    didSetInitialTab = true
                }
                async let libraryRefresh: () = libraryVM.refresh()
                async let searchExploreLoad: () = searchVM.loadExploreContentIfNeeded()
                async let pinsLoad: () = pinnedVM.loadPinnedItems()
                _ = await (libraryRefresh, searchExploreLoad, pinsLoad)
            }
            // Observation-extracted receivers — update @State only when specific values change,
            // avoiding full root view invalidation from singleton objectWillChange.
            .onReceive(networkMonitor.$networkState) { newValue in
                networkState = newValue
            }
            .onReceive(powerStateMonitor.$isLowPowerMode) { newValue in
                isLowPowerMode = newValue
            }
            .onReceive(settingsManager.objectWillChange) { _ in
                updateSettingsSnapshot()
            }
            .auxiliaryPresentationSheets(accentColor: accentColor)
            .addAccountPresentationSheet()
            rootView
                .stageFlowRotationSupport(isEnabled: selectedTabSupportsStageFlow)
                .background(
                    RootChromeFrameRegistrationView(
                        bottomPadding: miniPlayerBottomLift,
                        showsMiniPlayer: !isShowingNowPlaying && !miniPlayerSuppressed,
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
            get: { selectedRootTab },
            set: { handleTabTap($0) }
        )
    }
    
    private func handleTabTap(_ tag: TabItem) {
        if navigationCoordinator.selectedTab == tag {
            EnsembleLogger.debug("🧭 Tab selection repeated tab=\(String(describing: tag))")
            // Already on this tab — pop to root or focus search
            if !navigationCoordinator.pathSnapshot(for: tag).isEmpty {
                navigationCoordinator.popToRoot(tab: tag)
            } else if tag == .search {
                searchVM.requestFocus()
            }
        } else {
            EnsembleLogger.debug(
                "🧭 Tab selection changed from=\(String(describing: navigationCoordinator.selectedTab)) to=\(String(describing: tag))"
            )
            navigationCoordinator.selectedTab = tag
        }

        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    private func updateSettingsSnapshot() {
        let latestTabs = settingsManager.enabledTabs
        if latestTabs != enabledTabs {
            enabledTabs = latestTabs
            syncVisibleTabs(for: latestTabs)
        }

        let latestAccentColor = settingsManager.accentColor
        if latestAccentColor != accentColor {
            accentColor = latestAccentColor
        }

        let latestAuroraEnabled = settingsManager.auroraVisualizationEnabled
        if latestAuroraEnabled != auroraVisualizationEnabled {
            auroraVisualizationEnabled = latestAuroraEnabled
        }
    }

    private func syncVisibleTabs(for tabs: [TabItem]? = nil) {
        navigationCoordinator.routesHiddenTabsThroughMore = true
        navigationCoordinator.visibleTabs = Array(
            (tabs ?? enabledTabs).prefix(EnsembleScaffold.TabEditor.maximumTabBarItems)
        )
    }

    private func reconcileInitialTabSelection() {
        let selectedTab = navigationCoordinator.selectedTab
        let selectedPath = navigationCoordinator.pathSnapshot(for: selectedTab)

        switch MainTabInitialSelectionPolicy.initialResolution(
            selectedTab: selectedTab,
            selectedPath: selectedPath,
            barTabs: barTabs
        ) {
        case .preserve:
            return
        case .select(let tab):
            navigationCoordinator.selectedTab = tab
        case .routeThroughMore(let hiddenTab):
            navigationCoordinator.setPath([.view(hiddenTab)] + selectedPath, for: .settings)
            navigationCoordinator.setPath([], for: hiddenTab)
            navigationCoordinator.selectedTab = .settings
        }
    }
    
    @ViewBuilder
    private func tabRootView(
        for tab: TabItem,
        isMoreRoot: Bool = false,
        rootChromeSuppressed: Bool,
        isStageFlowActive: Bool
    ) -> some View {
        Group {
            if #available(iOS 16.0, macOS 13.0, *) {
                NavigationStack(path: navigationCoordinator.pathBinding(for: tab)) {
                    tabContentView(for: tab, isMoreRoot: isMoreRoot)
                }
            } else {
                NavigationView {
                    // iOS 15 Fallback: Support nested navigation by passing the remaining path
                    NavigationDestinationFactory.tabContent(
                        for: tab,
                        libraryVM: libraryVM,
                        nowPlayingVM: nowPlayingVM,
                        homeVM: homeVM,
                        searchVM: searchVM,
                        pinnedVM: pinnedVM,
                        isMoreRoot: isMoreRoot
                    )
                    .environment(\.showsProfileToolbar, shouldShowProfileButton(for: tab, isMoreRoot: isMoreRoot))
                    .auroraBackgroundSupport()
                    .background(legacyNavigationBridge(for: tab))
                }
                #if os(iOS)
                .navigationViewStyle(.stack)
                #endif
            }
        }
        .environment(\.isStageFlowActive, isStageFlowActive)
        .tabBarVisibility(isHidden: rootChromeSuppressed)
        .overlay(alignment: .bottom) {
            if showsPhoneAuroraOverlay &&
                selectedRootTab == tab &&
                auroraVisualizationEnabled &&
                !isShowingNowPlaying &&
                !rootChromeSuppressed &&
                navigationCoordinator.activeAuxiliaryPresentation == nil {
                AuroraVisualizationView(
                    playbackService: DependencyContainer.shared.playbackService,
                    consumer: .phoneOverlay,
                    accentColor: accentColor.color,
                    isPaused: isShowingNowPlaying,
                    isLowPowerMode: isLowPowerMode
                )
                .ignoresSafeArea(.all)
                .allowsHitTesting(false)
            }
        }
    }

    /// Tab content with navigation destinations registered for path-based push.
    @available(iOS 16.0, macOS 13.0, *)
    @ViewBuilder
    private func tabContentView(for tab: TabItem, isMoreRoot: Bool = false) -> some View {
        NavigationDestinationFactory.tabContent(
            for: tab,
            libraryVM: libraryVM,
            nowPlayingVM: nowPlayingVM,
            homeVM: homeVM,
            searchVM: searchVM,
            pinnedVM: pinnedVM,
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
        NavigationDestinationFactory.destinationContent(
            for: destination,
            libraryVM: libraryVM,
            nowPlayingVM: nowPlayingVM,
            homeVM: homeVM,
            searchVM: searchVM,
            pinnedVM: pinnedVM
        )
        .environment(\.showsProfileToolbar, false)
    }

    @ViewBuilder
    private func legacyNavigationBridge(for tab: TabItem) -> some View {
        let path = navigationCoordinator.pathSnapshot(for: tab)
        NestedNavigationLink(
            path: path,
            tab: tab,
            navigationCoordinator: navigationCoordinator,
            destinationBuilder: legacyDestinationView
        )
    }

    private func legacyDestinationView(for destination: NavigationCoordinator.Destination) -> AnyView {
        AnyView(destinationView(for: destination))
    }

    private func shouldShowProfileButton(for tab: TabItem, isMoreRoot: Bool) -> Bool {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        guard navigationCoordinator.pathSnapshot(for: tab).isEmpty else { return false }
        return isMoreRoot || barTabs.contains(tab)
        #else
        return false
        #endif
    }
}

private extension View {
    @ViewBuilder
    func tabBarVisibility(isHidden: Bool) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            self.toolbar(isHidden ? .hidden : .visible, for: .tabBar)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

enum MainTabStageFlowPolicy {
    static func activeRootTab(
        selectedRootTab: TabItem,
        morePath: [NavigationCoordinator.Destination],
        isPhone: Bool
    ) -> TabItem? {
        guard isPhone else {
            return nil
        }

        if supportsStageFlow(selectedRootTab) {
            return selectedRootTab
        }

        guard selectedRootTab == .settings else {
            return nil
        }

        return morePath
            .compactMap { destination -> TabItem? in
                guard case .view(let tab) = destination,
                      supportsStageFlow(tab) else {
                    return nil
                }
                return tab
            }
            .last
    }

    private static func supportsStageFlow(_ tab: TabItem) -> Bool {
        switch tab {
        case .albums, .songs, .playlists:
            return true
        default:
            return false
        }
    }
}

enum MainTabInitialSelectionPolicy {
    enum Resolution: Equatable {
        case preserve
        case select(TabItem)
        case routeThroughMore(TabItem)
    }

    static func rootTab(selectedTab: TabItem, barTabs: [TabItem]) -> TabItem {
        if barTabs.contains(selectedTab) || selectedTab == .settings {
            return selectedTab
        }
        return barTabs.first ?? .home
    }

    static func initialRootTab(
        selectedTab: TabItem,
        selectedPath: [NavigationCoordinator.Destination],
        barTabs: [TabItem]
    ) -> TabItem {
        if selectedTab == .home,
           selectedPath.isEmpty,
           let firstTab = barTabs.first,
           firstTab != .home {
            return firstTab
        }

        return rootTab(selectedTab: selectedTab, barTabs: barTabs)
    }

    static func initialResolution(
        selectedTab: TabItem,
        selectedPath: [NavigationCoordinator.Destination],
        barTabs: [TabItem]
    ) -> Resolution {
        if selectedTab == .home,
           selectedPath.isEmpty,
           let firstTab = barTabs.first,
           firstTab != .home {
            return .select(firstTab)
        }

        if barTabs.contains(selectedTab) || selectedTab == .settings {
            return .preserve
        }

        guard !selectedPath.isEmpty else {
            return .select(barTabs.first ?? .home)
        }

        return .routeThroughMore(selectedTab)
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

    @StateObject private var libraryVM: LibraryViewModel
    private let nowPlayingVM: NowPlayingViewModel
    @StateObject private var homeVM: HomeViewModel
    @StateObject private var searchVM: SearchViewModel
    @StateObject private var pinnedVM: PinnedViewModel
    @StateObject private var playlistsVM: PlaylistViewModel
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    private let settingsManager = DependencyContainer.shared.settingsManager
    private let pinManager = DependencyContainer.shared.pinManager
    @Environment(\.dependencies) private var deps
    @Environment(\.isViewportNowPlayingPresented) private var isViewportNowPlayingPresented
    @Environment(\.isSoftwareKeyboardVisible) private var isSoftwareKeyboardVisible
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    private enum CompactColumnPreference: Int {
        case sidebar
        case detail
    }

    @Binding private var selection: SidebarSelection?
    @State private var pinnedDetailPath: [NavigationCoordinator.Destination] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var compactColumnPreference: CompactColumnPreference = .sidebar
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?
    @State private var playlistForEditSheet: Playlist?
    @State private var playlistPendingRename: Playlist?
    @State private var playlistPendingRenameTitle = ""
    @State private var mergedPlaylistPendingRename: DisplayPlaylist?
    @State private var mergedPlaylistPendingRenameTitle = ""
    @State private var playlistPendingDelete: Playlist?
    @State private var mergedPlaylistPendingDelete: DisplayPlaylist?
    @SceneStorage("sidebarPinsExpanded") private var isPinsExpanded = true
    @SceneStorage("sidebarSmartPlaylistsExpanded") private var isSmartPlaylistsExpanded = true
    @SceneStorage("sidebarPlaylistsExpanded") private var isPlaylistsExpanded = true
    @State private var accentColor: AppAccentColor = DependencyContainer.shared.settingsManager.accentColor

    // Cached sidebar playlist items driven by .onReceive — avoids computed property
    // re-evaluation issues on macOS where NavigationSplitView can swallow updates.
    @State private var cachedSmartPlaylists: [SidebarPlaylistItem] = []
    @State private var cachedRegularPlaylists: [SidebarPlaylistItem] = []

    @MainActor
    public init(nowPlayingVM: NowPlayingViewModel, selection: Binding<SidebarSelection?>) {
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self.nowPlayingVM = nowPlayingVM
        self._homeVM = StateObject(wrappedValue: DependencyContainer.shared.makeHomeViewModel())
        self._searchVM = StateObject(wrappedValue: DependencyContainer.shared.makeSearchViewModel())
        self._pinnedVM = StateObject(wrappedValue: DependencyContainer.shared.makePinnedViewModel())
        self._playlistsVM = StateObject(wrappedValue: DependencyContainer.shared.makePlaylistViewModel())
        self._selection = selection
    }

    private var isShowingNowPlaying: Bool {
        isViewportNowPlayingPresented
    }

    private var sidebarPlaylistCacheInvalidations: AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            playlistsVM.$playlists.map { _ in () }.eraseToAnyPublisher(),
            playlistsVM.$sortedDisplayPlaylists.map { _ in () }.eraseToAnyPublisher(),
            playlistsVM.$playlistSortOption.map { _ in () }.eraseToAnyPublisher(),
            playlistsVM.$filterOptions.map { _ in () }.eraseToAnyPublisher(),
            playlistsVM.$isMergeEnabled.map { _ in () }.eraseToAnyPublisher(),
            libraryVM.$hasEnabledLibraries.map { _ in () }.eraseToAnyPublisher(),
            libraryVM.$isRestoringCloudSources.map { _ in () }.eraseToAnyPublisher()
        ])
        .eraseToAnyPublisher()
    }

    private func updateSettingsSnapshot() {
        let latestAccentColor = settingsManager.accentColor
        if latestAccentColor != accentColor {
            accentColor = latestAccentColor
        }
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
            return navigationCoordinator.pathSnapshot(for: tab).isEmpty
        case .playlist, .mergedPlaylist, .pin:
            return false
        }
    }

    /// Rebuild the cached sidebar playlist @State from the VM's current data.
    /// Uses @State instead of computed properties to survive NavigationSplitView
    /// re-layouts on macOS that can drop computed property changes.
    private func rebuildCachedSidebarPlaylists() {
        guard libraryVM.hasEnabledLibraries || libraryVM.isRestoringCloudSources else {
            cachedSmartPlaylists = []
            cachedRegularPlaylists = []
            return
        }

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
        let displayPlaylists = playlistsVM.sortedDisplayPlaylists.isEmpty
            ? DisplayPlaylist.group(sortedSidebarSourcePlaylists(), merge: true)
            : playlistsVM.sortedDisplayPlaylists

        return displayPlaylists.compactMap { dp in
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
                EnsembleLogger.debug("⚠️ SidebarView: skipping playlist row with no stable identity")
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

    private func handlePinnedSelectionRemoval(identities: Set<String>, fallback: SidebarSelection) {
        guard case .pin(let selectedID, let selectedSourceKey, _) = selection else { return }
        let selectedIdentity = PinnedItem.sourceScopedID(id: selectedID, sourceKey: selectedSourceKey)
        guard identities.contains(selectedIdentity) else { return }
        selectSidebar(fallback)
    }

    private func navigateFromPinnedMenu(to destination: NavigationCoordinator.Destination) {
        selectSidebar(SidebarSelection.selection(for: destination, fallback: selection))
        navigationCoordinator.routeFromMenu(
            to: destination,
            in: NavigationCoordinator.targetTab(for: destination)
        )
    }

    private func startPinnedPlaylistDelete(for playlist: Playlist) {
        guard let start = deps.playlistMutationWorkflow.beginDelete(
            playlist: playlist,
            scope: .sidebarPlaylist
        ) else { return }

        let deletingToast = start.pendingToast
        deps.toastCenter.show(deletingToast)

        Task {
            do {
                let result = try await deps.playlistMutationWorkflow.finishDelete(
                    playlist: playlist,
                    scope: .sidebarPlaylist
                )
                if result.outcome == .queued {
                    playlistsVM.applyOptimisticDelete(for: playlist)
                }

                handlePinnedSelectionRemoval(identities: [playlist.sourceScopedID], fallback: .library(.playlists))
                deps.pinMutationWorkflow.unpin(id: playlist.id, sourceKey: playlist.sourceCompositeKey ?? "")
                deps.toastCenter.dismiss(id: deletingToast.id)
                deps.toastCenter.show(result.successToast)
            } catch {
                deps.toastCenter.dismiss(id: deletingToast.id)
                deps.toastCenter.show(
                    deps.playlistMutationWorkflow.deleteFailureToast(
                        playlist: playlist,
                        error: error,
                        scope: .sidebarPlaylist
                    )
                )
            }
        }
    }

    private func renamePinnedPlaylist(_ playlist: Playlist, to newTitle: String) {
        guard let start = deps.playlistMutationWorkflow.beginRename(
            playlist: playlist,
            to: newTitle,
            scope: .sidebarPlaylist
        ) else { return }

        let renamingToast = start.pendingToast
        playlistsVM.applyOptimisticRename(for: playlist, newTitle: start.trimmedTitle)
        deps.toastCenter.show(renamingToast)

        Task {
            do {
                let result = try await deps.playlistMutationWorkflow.finishRename(
                    playlist: playlist,
                    trimmedTitle: start.trimmedTitle,
                    scope: .sidebarPlaylist
                )
                if result.outcome == .completed {
                    await playlistsVM.awaitRenamedPlaylistMaterialization(
                        for: playlist.id,
                        expectedTitle: start.trimmedTitle
                    )
                    deps.pinMutationWorkflow.updateTitle(
                        id: playlist.id,
                        sourceKey: playlist.sourceCompositeKey ?? "",
                        title: start.trimmedTitle
                    )
                }

                deps.toastCenter.dismiss(id: renamingToast.id)
                deps.toastCenter.show(result.successToast)
            } catch {
                playlistsVM.clearOptimisticRename(for: playlist.id)
                await playlistsVM.loadPlaylists()
                deps.toastCenter.dismiss(id: renamingToast.id)
                deps.toastCenter.show(
                    deps.playlistMutationWorkflow.renameFailureToast(
                        playlist: playlist,
                        error: error,
                        scope: .sidebarPlaylist
                    )
                )
            }
        }
    }

    private var mergedPlaylistRenameMessage: String {
        let count = mergedPlaylistPendingRename?.playlists.count ?? 0
        let serverLabel = count == 1 ? "server" : "servers"
        return "This will rename on \(count) \(serverLabel)."
    }

    public var body: some View {
        splitNavigationView
        .auxiliaryPresentationSheets(accentColor: accentColor)
        .onReceive(settingsManager.objectWillChange) { _ in
            updateSettingsSnapshot()
        }
        #if os(macOS)
        .onChange(of: navigationCoordinator.auxiliaryWindowRequest?.id) { _ in
            guard let request = navigationCoordinator.auxiliaryWindowRequest else { return }
            openWindow(id: request.destination.windowID)
            navigationCoordinator.consumeAuxiliaryWindowRequest()
            navigationCoordinator.dismissAuxiliaryPresentation()
        }
        #endif
        .addAccountPresentationSheet()
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
        .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
        .sheet(item: $playlistForEditSheet) { playlist in
            PlaylistDetailView(
                playlist: playlist,
                nowPlayingVM: nowPlayingVM,
                startInEditMode: true
            )
            .nativeSheetNavigationContainer()
        }
        .alert("Rename Playlist", isPresented: Binding(
            get: { playlistPendingRename != nil },
            set: { if !$0 { playlistPendingRename = nil } }
        )) {
            TextField("Playlist name", text: $playlistPendingRenameTitle)
            Button("Cancel", role: .cancel) {
                playlistPendingRename = nil
            }
            Button("Save") {
                guard let playlist = playlistPendingRename else { return }
                let title = playlistPendingRenameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                playlistPendingRename = nil
                renamePinnedPlaylist(playlist, to: title)
            }
            .disabled(playlistPendingRenameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose a new playlist name.")
        }
        .alert("Rename Playlist", isPresented: Binding(
            get: { mergedPlaylistPendingRename != nil },
            set: { if !$0 { mergedPlaylistPendingRename = nil } }
        )) {
            TextField("Playlist name", text: $mergedPlaylistPendingRenameTitle)
            Button("Cancel", role: .cancel) {
                mergedPlaylistPendingRename = nil
            }
            Button("Save") {
                guard let displayPlaylist = mergedPlaylistPendingRename else { return }
                let title = mergedPlaylistPendingRenameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                mergedPlaylistPendingRename = nil
                playlistsVM.applyOptimisticRenameForMerged(displayPlaylist, newTitle: title)
                for playlist in displayPlaylist.playlists {
                    renamePinnedPlaylist(playlist, to: title)
                }
            }
            .disabled(mergedPlaylistPendingRenameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(mergedPlaylistRenameMessage)
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
                    identities: Set(displayPlaylist.playlists.map(\.sourceScopedID)),
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
            rebuildCachedSidebarPlaylists()
        }
    }

    private var sidebarSelectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { selection },
            set: { selectSidebar($0) }
        )
    }

    private func selectSidebar(_ newSelection: SidebarSelection?) {
        if let tab = newSelection?.correspondingTab {
            EnsembleLogger.debug("🧭 Sidebar selection changed to=\(String(describing: tab))")
            if navigationCoordinator.selectedTab != tab {
                navigationCoordinator.selectedTab = tab
            }
        }

        if selection != newSelection {
            selection = newSelection
        }

        clearPinnedDetailPathAfterSelectionChange(to: newSelection)

        #if os(iOS)
        if #available(iOS 17.0, *), newSelection != nil {
            compactColumnPreference = .detail
        }
        #endif
    }

    private func clearPinnedDetailPathAfterSelectionChange(to newSelection: SidebarSelection?) {
        guard !pinnedDetailPath.isEmpty else { return }
        guard newSelection?.isPinnedDetailSelection != true else { return }

        Task { @MainActor in
            await Task.yield()
            guard selection?.isPinnedDetailSelection != true else { return }
            guard !pinnedDetailPath.isEmpty else { return }
            pinnedDetailPath.removeAll()
        }
    }

    private var sidebarColumn: some View {
        List(selection: sidebarSelectionBinding) {
            // Search always appears first
            Label("Search", systemImage: EnsembleDesign.Icon.search)
                .tag(SidebarSelection.library(.search))

            // Library section (non-collapsible)
            Section("Library") {
                Label("Home", systemImage: EnsembleDesign.Icon.home)
                    .tag(SidebarSelection.library(.home))
                Label("Songs", systemImage: EnsembleDesign.Icon.musicNote)
                    .tag(SidebarSelection.library(.songs))
                Label("Artists", systemImage: EnsembleDesign.Icon.artist)
                    .tag(SidebarSelection.library(.artists))
                Label("Albums", systemImage: EnsembleDesign.Icon.album)
                    .tag(SidebarSelection.library(.albums))
                Label("Genres", systemImage: EnsembleDesign.Icon.genreEmpty)
                    .tag(SidebarSelection.library(.genres))
                Label("Favorites", systemImage: EnsembleDesign.Icon.favoriteFilled)
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
                Label("All Playlists", systemImage: EnsembleDesign.Icon.playlist)
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
                    height: isShowingNowPlaying || isSoftwareKeyboardVisible
                        ? 0
                        : TrackListLayoutMetrics.miniPlayerContainerInset
                )
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 260, max: 260)
        .toolbar {
            #if os(macOS)
            EnsembleToolbarLeadingSpacer()
            #endif
            ToolbarItemGroup(placement: .primaryActionIfAvailable) {
                Button { navigationCoordinator.openDownloads() } label: {
                    Image(systemName: EnsembleDesign.Icon.download)
                }
                .help("Downloads")
                ProfileToolbarButton()
            }
        }
        // Sync cached sidebar playlists from VM publisher. Using @State + .onReceive
        // instead of computed properties ensures updates survive NavigationSplitView
        // re-layouts on macOS that can swallow computed property changes.
        .onReceive(sidebarPlaylistCacheInvalidations) { _ in
            rebuildCachedSidebarPlaylists()
        }
        .onAppear {
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

    @ViewBuilder
    private var detailView: some View {
        detailColumnNavigationHost {
            NavigationStack(path: activeDetailPathBinding) {
                detailChromeRegistrationHost {
                    detailRootContentView
                }
                .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                    detailChromeRegistrationHost {
                        destinationView(for: destination)
                    }
                }
            }
        }
        .auroraBackgroundSupport()
    }

    @ViewBuilder
    private var detailRootContentView: some View {
        switch selection {
        case .library(let tab):
            sidebarContentView(for: tab)
        case .playlist(let id, let sourceKey):
            PlaylistDetailLoader(
                playlistId: id,
                playlistSourceKey: sourceKey,
                nowPlayingVM: nowPlayingVM
            )
        case .mergedPlaylist(let title, let isSmart):
            MergedPlaylistDetailLoader(
                title: title,
                isSmart: isSmart,
                nowPlayingVM: nowPlayingVM
            )
        case .pin(let id, let sourceKey, let type):
            pinnedDetailRootView(id: id, sourceKey: sourceKey, type: type)
        case .none:
            sidebarContentView(for: .home)
        }
    }

    private var activeDetailPathBinding: Binding<[NavigationCoordinator.Destination]> {
        Binding(
            get: { activeDetailPathSnapshot },
            set: { setActiveDetailPath($0) }
        )
    }

    private var activeDetailPathSnapshot: [NavigationCoordinator.Destination] {
        switch selection {
        case .library(let tab):
            return navigationCoordinator.pathSnapshot(for: tab)
        case .playlist, .mergedPlaylist:
            return navigationCoordinator.pathSnapshot(for: .playlists)
        case .pin:
            return pinnedDetailPath
        case .none:
            return navigationCoordinator.pathSnapshot(for: .home)
        }
    }

    private func setActiveDetailPath(_ newPath: [NavigationCoordinator.Destination]) {
        switch selection {
        case .library(let tab):
            navigationCoordinator.setPath(newPath, for: tab)
        case .playlist, .mergedPlaylist:
            navigationCoordinator.setPath(newPath, for: .playlists)
        case .pin:
            guard pinnedDetailPath != newPath else { return }
            pinnedDetailPath = newPath
        case .none:
            navigationCoordinator.setPath(newPath, for: .home)
        }
    }

    private var detailContainerView: some View {
        detailView
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func pinnedDetailRootView(id: String, sourceKey: String?, type: PinnedItemType) -> some View {
        if let resolvedPin = resolvedPin(id: id, sourceKey: sourceKey, type: type) {
            switch resolvedPin {
            case .album(let album, _):
                AlbumDetailView(album: album, nowPlayingVM: nowPlayingVM)
            case .artist(let artist, _):
                ArtistDetailView(artist: artist, nowPlayingVM: nowPlayingVM)
            case .playlist(let playlist, _):
                PlaylistDetailView(playlist: playlist, nowPlayingVM: nowPlayingVM)
            case .mergedPlaylist(let displayPlaylist, _):
                MergedPlaylistDetailView(displayPlaylist: displayPlaylist, nowPlayingVM: nowPlayingVM)
            }
        } else {
            switch type {
            case .album:
                AlbumDetailLoader(albumId: id, albumSourceKey: sourceKey, nowPlayingVM: nowPlayingVM)
            case .artist:
                ArtistDetailLoader(artistId: id, artistSourceKey: sourceKey, nowPlayingVM: nowPlayingVM)
            case .playlist:
                PlaylistDetailLoader(playlistId: id, playlistSourceKey: sourceKey, nowPlayingVM: nowPlayingVM)
            }
        }
    }

    private func resolvedPin(id: String, sourceKey: String?, type: PinnedItemType) -> ResolvedPin? {
        let identity = PinnedItem.sourceScopedID(id: id, sourceKey: sourceKey)
        return pinnedVM.resolvedPins.first { pin in
            switch pin {
            case let .album(_, pinnedItem),
                 let .artist(_, pinnedItem),
                 let .playlist(_, pinnedItem):
                return pinnedItem.type == type && pinnedItem.sourceScopedID == identity
            case let .mergedPlaylist(_, pinnedItems):
                return type == .playlist && pinnedItems.contains { $0.sourceScopedID == identity }
            }
        }
    }

    @ViewBuilder
    private func detailColumnNavigationHost<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        GeometryReader { proxy in
            content()
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .background(
                    RootChromeFrameRegistrationView(
                        bottomPadding: TrackListLayoutMetrics.detailMiniPlayerBottomLift(
                            safeAreaBottom: proxy.safeAreaInsets.bottom
                        ),
                        contentLeadingInset: proxy.safeAreaInsets.leading,
                        centersInRootHorizontalSpace: isSidebarCollapsedForRootChrome,
                        showsMiniPlayer: !isShowingNowPlaying && !isSoftwareKeyboardVisible,
                        priority: 10_000
                    )
                )
        }
    }

    /// Keep pushed detail content from registering transient navigation-transition frames.
    /// The stable detail-column host owns root chrome registration.
    @ViewBuilder
    private func detailChromeRegistrationHost<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var isSidebarCollapsedForRootChrome: Bool {
        #if os(iOS)
        switch columnVisibility {
        case .detailOnly:
            return true
        default:
            return false
        }
        #else
        return false
        #endif
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
            detailColumnRootChromeRegistrationHost {
                detailContainerView
            }
                .macEditorToolbarRoleIfAvailable()
        }
        .navigationSplitViewStyle(.balanced)
        #else
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
        } detail: {
            detailColumnRootChromeRegistrationHost {
                detailContainerView
            }
                .macEditorToolbarRoleIfAvailable()
        }
        .navigationSplitViewStyle(.balanced)
        #endif
    }

    @ViewBuilder
    private func detailColumnRootChromeRegistrationHost<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        GeometryReader { proxy in
            content()
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .background(
                    RootChromeFrameRegistrationView(
                        bottomPadding: TrackListLayoutMetrics.detailMiniPlayerBottomLift(
                            safeAreaBottom: proxy.safeAreaInsets.bottom
                        ),
                        contentLeadingInset: proxy.safeAreaInsets.leading,
                        centersInRootHorizontalSpace: isSidebarCollapsedForRootChrome,
                        showsMiniPlayer: !isShowingNowPlaying && !isSoftwareKeyboardVisible,
                        priority: 20_000
                    )
                )
        }
    }

    /// Sidebar section content with navigation destinations registered for path-based push
    @ViewBuilder
    private func sidebarContentView(for tab: TabItem) -> some View {
        Group {
            if tab == .playlists {
                PlaylistsView(nowPlayingVM: nowPlayingVM, viewModel: playlistsVM)
            } else {
                NavigationDestinationFactory.tabContent(
                    for: tab,
                    libraryVM: libraryVM,
                    nowPlayingVM: nowPlayingVM,
                    homeVM: homeVM,
                    searchVM: searchVM,
                    pinnedVM: pinnedVM
                )
            }
        }
        .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
            detailChromeRegistrationHost {
                destinationView(for: destination)
            }
        }
    }

    /// Sidebar row for a pinned item, showing artwork preview instead of an icon.
    @ViewBuilder
    private func sidebarPinRow(_ pin: ResolvedPin) -> some View {
        let artworkDimension = EnsembleScaffold.Sidebar.artworkDimension
        let cornerRadius: CGFloat = pin.pinnedItem.type == .artist
            ? ArtworkCornerRadius.circle(for: artworkDimension)
            : ArtworkCornerRadius.square(for: artworkDimension)
        switch pin {
        case .artist(let artist, let pinnedItem):
            Label {
                Text(pinnedItem.title)
            } icon: {
                ArtworkView(artist: artist, size: .tiny, cornerRadius: cornerRadius, isResponsive: true)
                    .frame(width: artworkDimension, height: artworkDimension)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .tag(SidebarSelection.pin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey, type: pinnedItem.type))
            .contextMenu {
                ArtistActionsContextMenu(
                    artist: artist,
                    nowPlayingVM: nowPlayingVM,
                    toastNamespace: "sidebar-artist-menu",
                    customPinAction: { isPinned in
                        if isPinned {
                            handlePinnedSelectionRemoval(identities: [pinnedItem.sourceScopedID], fallback: .library(.artists))
                            deps.pinMutationWorkflow.unpin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey)
                        } else {
                            deps.pinMutationWorkflow.pin(
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
                    .frame(width: artworkDimension, height: artworkDimension)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .tag(SidebarSelection.pin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey, type: pinnedItem.type))
            .contextMenu {
                AlbumActionsContextMenu(
                    album: album,
                    nowPlayingVM: nowPlayingVM,
                    presentPlaylistPicker: { tracks, title in
                        playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks, title: title)
                    },
                    toastNamespace: "sidebar-album-menu",
                    navigateToArtist: { artistID in
                        navigateFromPinnedMenu(
                            to: .artist(
                                id: artistID,
                                sourceKey: album.sourceCompositeKey ?? pinnedItem.sourceCompositeKey
                            )
                        )
                    },
                    onGetInfo: {
                        libraryItemInfoRequest = .album(album)
                    },
                    customPinAction: { isPinned in
                        if isPinned {
                            handlePinnedSelectionRemoval(identities: [pinnedItem.sourceScopedID], fallback: .library(.albums))
                            deps.pinMutationWorkflow.unpin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey)
                        } else {
                            deps.pinMutationWorkflow.pin(
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
                    .frame(width: artworkDimension, height: artworkDimension)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .tag(SidebarSelection.pin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey, type: pinnedItem.type))
            .contextMenu {
                PlaylistActionsContextMenu(
                    playlist: playlist,
                    nowPlayingVM: nowPlayingVM,
                    toastNamespace: "sidebar-playlist-menu",
                    onGetInfo: {
                        libraryItemInfoRequest = .playlist(playlist)
                    },
                    onRename: {
                        playlistPendingRenameTitle = playlist.title
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
                            handlePinnedSelectionRemoval(identities: [pinnedItem.sourceScopedID], fallback: .library(.playlists))
                            deps.pinMutationWorkflow.unpin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey)
                        } else {
                            deps.pinMutationWorkflow.pin(
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
                    playlist: displayPlaylist.primaryPlaylist,
                    size: .tiny,
                    cornerRadius: ArtworkCornerRadius.square(for: artworkDimension),
                    isResponsive: true
                )
                .frame(width: artworkDimension, height: artworkDimension)
                .clipShape(RoundedRectangle(cornerRadius: ArtworkCornerRadius.square(for: artworkDimension), style: .continuous))
            }
            .tag(SidebarSelection.pin(
                id: pinnedItems[0].id,
                sourceKey: pinnedItems[0].sourceCompositeKey,
                type: pinnedItems[0].type
            ))
            .contextMenu {
                MergedPlaylistActionsContextMenu(
                    displayPlaylist: displayPlaylist,
                    nowPlayingVM: nowPlayingVM,
                    toastNamespace: "sidebar-merged-playlist-menu",
                    context: .sidebar,
                    onRename: {
                        mergedPlaylistPendingRenameTitle = displayPlaylist.title
                        mergedPlaylistPendingRename = displayPlaylist
                    },
                    onDelete: {
                        mergedPlaylistPendingDelete = displayPlaylist
                    },
                    onUnpinAll: {
                        handlePinnedSelectionRemoval(
                            identities: Set(pinnedItems.map(\.sourceScopedID)),
                            fallback: .library(.playlists)
                        )
                        deps.pinMutationWorkflow.unpinAll(identities: Set(pinnedItems.map(\.sourceScopedID)))
                    }
                )
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
                cacheHint: PersistentArtworkCacheHint(
                    ratingKey: playlist.playlistID,
                    kind: .playlist,
                    sourcePath: playlist.compositePath
                ),
                size: .tiny,
                cornerRadius: ArtworkCornerRadius.square(for: EnsembleScaffold.Sidebar.artworkDimension),
                isResponsive: true
            )
            .frame(width: EnsembleScaffold.Sidebar.artworkDimension, height: EnsembleScaffold.Sidebar.artworkDimension)
            .clipShape(RoundedRectangle(cornerRadius: ArtworkCornerRadius.square(for: EnsembleScaffold.Sidebar.artworkDimension), style: .continuous))
        }

        if playlist.isMerged {
            sidebarPlaylistDropDestination(artworkLabel, playlist: playlist)
                .tag(SidebarSelection.mergedPlaylist(title: playlist.title, isSmart: playlist.isSmart))
        } else {
            sidebarPlaylistDropDestination(artworkLabel, playlist: playlist)
                .tag(SidebarSelection.playlist(id: playlist.playlistID, sourceKey: playlist.sourceKey))
        }
    }

    @ViewBuilder
    private func sidebarPlaylistDropDestination<Content: View>(_ content: Content, playlist: SidebarPlaylistItem) -> some View {
        SidebarPlaylistDragDropHost(
            content: content,
            playlist: playlist,
            libraryVM: libraryVM,
            playlistsVM: playlistsVM,
            nowPlayingVM: nowPlayingVM
        )
    }

    private struct SidebarPlaylistDragDropHost<Content: View>: View {
        @Environment(\.dependencies) private var deps

        let content: Content
        let playlist: SidebarPlaylistItem
        let libraryVM: LibraryViewModel
        let playlistsVM: PlaylistViewModel
        let nowPlayingVM: NowPlayingViewModel
        private let playlistDropResolver = PlaylistDropResolver()
        @State private var isDropTargeted = false

        var body: some View {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(dropTargetBackground)
                .onDrop(of: MediaDragPayload.contentTypes, isTargeted: $isDropTargeted) { providers in
                    handleSidebarPlaylistDrop(providers, onto: playlist)
                }
                #if os(macOS)
                .background {
                    MacSidebarPlaylistDropBridge(isTargeted: $isDropTargeted) { payload in
                        handleSidebarPlaylistDrop(payload, onto: playlist)
                    }
                }
                .help("Drop songs, albums, or playlists here to add tracks.")
                #endif
        }

        private var dropTargetBackground: some View {
            RoundedRectangle(
                cornerRadius: EnsembleScaffold.BrowseSelection.cornerRadius,
                style: .continuous
            )
            .fill(isDropTargeted ? EnsembleDesign.Color.accent.opacity(0.16) : Color.clear)
        }

        private func handleSidebarPlaylistDrop(_ providers: [NSItemProvider], onto playlist: SidebarPlaylistItem) -> Bool {
            guard MediaDragPayload.canLoad(from: providers) else {
                EnsembleLogger.debug(
                    "Sidebar playlist drop ignored: unsupported provider for target=\(playlist.id) providerTypes=\(MediaDragPayload.debugRegisteredTypeIdentifiers(for: providers))"
                )
                return false
            }

            Task { @MainActor in
                guard let payload = await MediaDragPayload.load(from: providers) else {
                    EnsembleLogger.debug(
                        "Sidebar playlist drop failed: payload unresolved for target=\(playlist.id) providerTypes=\(MediaDragPayload.debugRegisteredTypeIdentifiers(for: providers))"
                    )
                    showSidebarDropToast(
                        style: .warning,
                        title: "Drop not supported",
                        message: "That item could not be resolved.",
                        dedupeKey: "playlist-drop-unresolved-payload"
                    )
                    return
                }
                await performSidebarPlaylistDrop(payload, onto: playlist)
            }
            return true
        }

        private func handleSidebarPlaylistDrop(_ payload: MediaDragPayload, onto playlist: SidebarPlaylistItem) -> Bool {
            Task { @MainActor in
                await performSidebarPlaylistDrop(payload, onto: playlist)
            }
            return true
        }

        @MainActor
        private func performSidebarPlaylistDrop(_ payload: MediaDragPayload, onto sidebarPlaylist: SidebarPlaylistItem) async {
            do {
                let resolution = try await playlistDropResolver.resolve(
                    references: payload.dropReferences,
                    target: dropTargetReference(for: sidebarPlaylist),
                    tracks: libraryVM.tracks,
                    albums: libraryVM.albums,
                    playlists: playlistsVM.playlists,
                    loadAlbumTracks: { album in
                        let detailVM = DependencyContainer.shared.makeAlbumDetailViewModel(album: album)
                        await detailVM.loadTracks()
                        return detailVM.tracks
                    },
                    loadPlaylistTracks: { playlist in
                        let detailVM = DependencyContainer.shared.makePlaylistDetailViewModel(playlist: playlist)
                        await detailVM.loadTracks()
                        return detailVM.tracks
                    }
                )
                let outcome = try await nowPlayingVM.addTracksOptimistically(
                    resolution.tracks,
                    to: resolution.targetPlaylist
                )
                EnsembleLogger.debug(
                    "Sidebar playlist drop completed: target=\(resolution.targetPlaylist.id) tracks=\(resolution.tracks.count) outcome=\(String(describing: outcome))"
                )
            } catch let error as PlaylistDropResolutionError {
                handleSidebarDropResolutionError(error, sidebarPlaylist: sidebarPlaylist)
            } catch {
                EnsembleLogger.debug("Sidebar playlist drop failed: target=\(sidebarPlaylist.playlistID) error=\(error.localizedDescription)")
                showSidebarDropToast(
                    style: .error,
                    title: "Couldn't add tracks",
                    message: error.localizedDescription,
                    dedupeKey: "playlist-drop-add-failed-\(sidebarPlaylist.playlistID)"
                )
            }
        }

        private func dropTargetReference(for item: SidebarPlaylistItem) -> PlaylistDropTargetReference {
            PlaylistDropTargetReference(
                id: item.playlistID,
                sourceKey: item.sourceKey,
                title: item.title,
                isSmart: item.isSmart,
                isMerged: item.isMerged
            )
        }

        private func handleSidebarDropResolutionError(
            _ error: PlaylistDropResolutionError,
            sidebarPlaylist: SidebarPlaylistItem
        ) {
            switch error {
            case .mergedTarget:
                EnsembleLogger.debug("Sidebar playlist drop rejected: merged target=\(sidebarPlaylist.id)")
                showSidebarDropToast(
                    style: .warning,
                    title: "Choose a playlist",
                    message: "Drop onto one editable playlist, not a merged group.",
                    dedupeKey: "playlist-drop-merged-target"
                )

            case .unresolvedTarget:
                EnsembleLogger.debug("Sidebar playlist drop rejected: unresolved target=\(sidebarPlaylist.id)")
                showSidebarDropToast(
                    style: .warning,
                    title: "Playlist unavailable",
                    message: "The destination playlist could not be resolved.",
                    dedupeKey: "playlist-drop-target-unresolved-\(sidebarPlaylist.id)"
                )

            case .smartTarget:
                EnsembleLogger.debug("Sidebar playlist drop rejected: smart target=\(sidebarPlaylist.playlistID)")
                showSidebarDropToast(
                    style: .warning,
                    title: "Smart playlist",
                    message: "Smart playlists cannot be edited manually.",
                    dedupeKey: "playlist-drop-smart-target-\(sidebarPlaylist.playlistID)"
                )

            case .unresolvedItem(let title):
                showUnresolvedDropToast(title: title)

            case .smartSource(let title):
                showSidebarDropToast(
                    style: .warning,
                    title: "Smart playlist",
                    message: "Smart playlist tracks cannot be copied from a drag.",
                    dedupeKey: "playlist-drop-smart-source-\(title)"
                )

            case .crossSource(let itemTitle, let playlistTitle):
                showCrossSourceDropToast(itemTitle: itemTitle, playlistTitle: playlistTitle)

            case .emptyDrop:
                showSidebarDropToast(
                    style: .warning,
                    title: "Nothing to add",
                    message: "No playable tracks were found in the drop.",
                    dedupeKey: "playlist-drop-empty"
                )
            }
        }

        private func showUnresolvedDropToast(title: String) {
            showSidebarDropToast(
                style: .warning,
                title: "Drop not added",
                message: "\"\(title)\" could not be resolved in the local library.",
                dedupeKey: "playlist-drop-unresolved-\(title)"
            )
        }

        private func showCrossSourceDropToast(itemTitle: String, playlistTitle: String) {
            showSidebarDropToast(
                style: .warning,
                title: "Different source",
                message: "\"\(itemTitle)\" cannot be added to \"\(playlistTitle)\" from another source.",
                dedupeKey: "playlist-drop-cross-source-\(itemTitle)-\(playlistTitle)"
            )
        }

        private func showSidebarDropToast(
            style: ToastStyle,
            title: String,
            message: String,
            dedupeKey: String
        ) {
            deps.toastCenter.show(
                ToastPayload(
                    style: style,
                    iconSystemName: style == .error ? "exclamationmark.triangle.fill" : "exclamationmark.triangle",
                    title: title,
                    message: message,
                    dedupeKey: dedupeKey
                )
            )
        }
    }

    @ViewBuilder
    private func destinationView(for destination: NavigationCoordinator.Destination) -> some View {
        NavigationDestinationFactory.destinationContent(
            for: destination,
            libraryVM: libraryVM,
            nowPlayingVM: nowPlayingVM,
            homeVM: homeVM,
            searchVM: searchVM,
            pinnedVM: pinnedVM
        )
    }
}
