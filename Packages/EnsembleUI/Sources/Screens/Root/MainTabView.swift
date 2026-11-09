import EnsembleDesignTokens
import EnsembleCore
import EnsembleDomain
import Combine
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Main tab bar view for iPhone (5-tab classic iOS style)
public struct MainTabView: View {
    var isAdaptivePhoneRoot = false
    let viewModels: RootScreenModels
    private let nowPlayingVM: NowPlayingViewModel
    @Namespace private var mediaNavigationNamespace
    private var settingsManager: SettingsManager { deps.settingsManager }
    private var networkMonitor: NetworkMonitor { deps.networkMonitor }
    private var powerStateMonitor: PowerStateMonitor { deps.powerStateMonitor }
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(DependencyContainer.self) private var deps
    @Environment(\.isViewportNowPlayingPresented) private var isViewportNowPlayingPresented
    @Environment(\.isSoftwareKeyboardVisible) private var isSoftwareKeyboardVisible
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var didSetInitialTab = false
    // Settings fields copied out of the one `AppSettings` value, so an unrelated
    // settings change does not re-render the root.
    @State private var enabledTabs: [TabItem]
    @State private var accentColor: AppAccentColor
    @State private var auroraVisualizationEnabled: Bool
    @State private var tabInteractionGeneration = 0
    @State private var tabBarBottomClearance: CGFloat = 0
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

    init(nowPlayingVM: NowPlayingViewModel, viewModels: RootScreenModels, isAdaptivePhoneRoot: Bool = false) {
        self.isAdaptivePhoneRoot = isAdaptivePhoneRoot
        self.nowPlayingVM = nowPlayingVM
        self.viewModels = viewModels
        let settings = viewModels.dependencies.settingsManager
        _enabledTabs = State(initialValue: settings.enabledTabs)
        _accentColor = State(initialValue: settings.accentColor)
        _auroraVisualizationEnabled = State(initialValue: settings.auroraVisualizationEnabled)
    }

    private var libraryVM: LibraryViewModel {
        viewModels.library
    }

    private var searchVM: SearchViewModel {
        viewModels.search
    }

    private var pinnedVM: PinnedViewModel {
        viewModels.pinned
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
            navigationPath: navigationCoordinator.pathSnapshot(for: selectedRootTab),
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
        return MainTabStageFlowPolicy.isActive(
            size: size, hasEligibleRoot: activeTab != nil,
            isCompactHeight: verticalSizeClass == .compact
        )
        #else
        return false
        #endif
    }

    public var body: some View {
        GeometryReader { geometry in
            let miniPlayerBottomLift = TrackListLayoutMetrics.rootMiniPlayerBottomLift(
                safeAreaBottom: geometry.safeAreaInsets.bottom,
                tabBarBottomClearance: tabBarBottomClearance
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
                .tabViewStyle(.automatic)
            }
                .tabBarBottomClearanceProbe($tabBarBottomClearance)
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
                async let libraryRefresh: () = libraryVM.loadLibraryIfNeeded()
                async let pinsLoad: () = pinnedVM.loadPinnedItemsIfNeeded()
                _ = await (libraryRefresh, pinsLoad)
            }
            .onChange(of: settingsManager.settings) {
                updateSettingsSnapshot()
            }
            .addAccountPresentationSheet()
            rootView
                .allowsHitTesting(!isShowingNowPlaying)
                .accessibilityHidden(isShowingNowPlaying)
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
                            networkState: networkMonitor.networkState,
                            topInset: geometry.safeAreaInsets.top
                        )
                    }
                }
        }
    }

    @ViewBuilder
    private func tabBarVisibility<Content: View>(_ content: Content, isHidden: Bool) -> some View {
        #if os(iOS)
        content.toolbar(isHidden ? .hidden : .visible, for: .tabBar)
        #else
        content
        #endif
    }

    private var tabBinding: Binding<TabItem> {
        Binding(
            get: { selectedRootTab },
            set: { handleTabTap($0) }
        )
    }

    private func handleTabTap(_ tag: TabItem) {
        markTabInteraction()

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

    private func markTabInteraction() {
        tabInteractionGeneration += 1
        let generation = tabInteractionGeneration
        let scheduler = deps.foregroundWorkScheduler
        scheduler.beginInteraction(.navigating)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard tabInteractionGeneration == generation else { return }
            scheduler.endInteraction(.navigating)
        }
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
            NavigationStack(path: navigationCoordinator.pathBinding(for: tab, isActive: {
                !isAdaptivePhoneRoot || navigationCoordinator.routesHiddenTabsThroughMore
            })) {
                tabContentView(for: tab, isMoreRoot: isMoreRoot)
            }
        }
        .adaptiveTabChrome(
            isSelected: selectedRootTab == tab,
            showsMiniPlayer: !isShowingNowPlaying && !rootChromeSuppressed && !isSoftwareKeyboardVisible
        )
        .environment(\.mediaNavigationTransitionNamespace, mediaNavigationNamespace)
        .environment(\.isStageFlowActive, isStageFlowActive)
        .tabBarVisibility(isHidden: rootChromeSuppressed)
        .overlay(alignment: .bottom) {
            if showsPhoneAuroraOverlay &&
                selectedRootTab == tab &&
                auroraVisualizationEnabled &&
                nowPlayingVM.currentTrack?.sourceCapabilities.supportsWaveform != false &&
                !isShowingNowPlaying &&
                !rootChromeSuppressed &&
                navigationCoordinator.activeAuxiliaryPresentation == nil {
                AuroraVisualizationView(
                    playbackService: deps.playbackService,
                    consumer: .phoneOverlay,
                    accentColor: accentColor.color,
                    isPaused: isShowingNowPlaying,
                    isLowPowerMode: powerStateMonitor.isLowPowerMode
                )
                .ignoresSafeArea(.all)
                .allowsHitTesting(false)
            }
        }
    }

    /// Tab content with navigation destinations registered for path-based push.
    @ViewBuilder
    private func tabContentView(for tab: TabItem, isMoreRoot: Bool = false) -> some View {
        NavigationDestinationFactory.tabContent(
            for: tab,
            nowPlayingVM: nowPlayingVM,
            viewModels: viewModels,
            mediaNavigationNamespace: mediaNavigationNamespace,
            isMoreRoot: isMoreRoot,
            isSelectedRoot: selectedRootTab == tab
        )
        .rootProfileToolbar(isVisible: shouldShowProfileButton(for: tab, isMoreRoot: isMoreRoot))
        .auroraBackgroundSupport()
        .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
            destinationView(for: destination)
                .auroraBackgroundSupport()
        }
    }

    @ViewBuilder
    private func destinationView(for destination: NavigationCoordinator.Destination) -> some View {
        NavigationDestinationFactory.destinationContent(
            for: destination,
            nowPlayingVM: nowPlayingVM,
            viewModels: viewModels,
            mediaNavigationNamespace: mediaNavigationNamespace
        )
        .id(destination)
    }

    private func shouldShowProfileButton(for tab: TabItem, isMoreRoot: Bool) -> Bool {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        return isMoreRoot || barTabs.contains(tab)
        #else
        return false
        #endif
    }
}

private extension View {
    @ViewBuilder
    func rootProfileToolbar(isVisible: Bool) -> some View {
        #if os(iOS)
        self.toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isVisible {
                    ProfileToolbarButton()
                }
            }
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func tabBarVisibility(isHidden: Bool) -> some View {
        #if os(iOS)
        self.toolbar(isHidden ? .hidden : .visible, for: .tabBar)
        #else
        self
        #endif
    }
}

enum MainTabStageFlowPolicy {
    static func isActive(size: CGSize, hasEligibleRoot: Bool, isCompactHeight: Bool) -> Bool {
        hasEligibleRoot && isCompactHeight && size.width > size.height
    }

    static func activeRootTab(
        selectedRootTab: TabItem,
        navigationPath: [NavigationCoordinator.Destination],
        isPhone: Bool
    ) -> TabItem? {
        guard isPhone else {
            return nil
        }

        if supportsStageFlow(selectedRootTab) {
            return navigationPath.isEmpty ? selectedRootTab : nil
        }

        guard selectedRootTab == .settings,
              navigationPath.count == 1,
              case .view(let tab) = navigationPath[0],
              supportsStageFlow(tab) else { return nil }
        return tab
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

        return .routeThroughMore(selectedTab)
    }
}
