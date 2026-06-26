import Combine
import EnsembleCore
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// Root view that renders the main content directly (no auth gate)
@available(iOS 15.0, macOS 12.0, *)
public struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    private let powerStateMonitor = DependencyContainer.shared.powerStateMonitor
    @StateObject private var navigationCoordinator: NavigationCoordinator
    @StateObject private var nowPlayingVM: NowPlayingViewModel
    @StateObject private var artworkDetailBackgroundContinuity = ArtworkDetailBackgroundContinuityStore()
    @StateObject private var artistDetailArtworkContinuity = ArtistDetailArtworkContinuityStore()
    @State private var isNowPlayingPresented = false
    @State private var sidebarSelection: SidebarSelection? = .library(.home)
    @State private var rootSidebarChromeRegistration: RootSidebarChromeRegistration = .absent
    @State private var isLowPowerMode = DependencyContainer.shared.powerStateMonitor.isLowPowerMode
    @State private var isSoftwareKeyboardVisible = false
    @Namespace private var playerNamespace
    private let artworkAnimationID = "nowPlayingArtwork"

    private var showsRootAurora: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
        #else
        true
        #endif
    }

    public init() {
        let navigationCoordinator = NavigationCoordinator(
            foregroundWorkScheduler: DependencyContainer.shared.foregroundWorkScheduler
        )
        _navigationCoordinator = StateObject(wrappedValue: navigationCoordinator)
        _nowPlayingVM = StateObject(
            wrappedValue: DependencyContainer.shared.makeNowPlayingViewModel(
                navigationCoordinator: navigationCoordinator
            )
        )
    }

    public var body: some View {
        RootSceneLayerHost(
            nowPlayingVM: nowPlayingVM,
            playbackService: DependencyContainer.shared.playbackService,
            accentColor: settingsManager.accentColor.color,
            isAuroraEnabled: settingsManager.auroraVisualizationEnabled && showsRootAurora,
            isLowPowerMode: isLowPowerMode,
            isNowPlayingPresented: isNowPlayingPresented,
            isSoftwareKeyboardVisible: isSoftwareKeyboardVisible,
            sidebarChromeRegistration: rootSidebarChromeRegistration,
            supportsViewportNowPlayingPresentation: supportsViewportNowPlayingPresentation,
            namespace: playerNamespace,
            animationID: artworkAnimationID,
            presentNowPlaying: presentNowPlayingFromMiniPlayer,
            dismissNowPlaying: dismissNowPlaying
        ) {
            mainContentView
        }
        .environment(\.isViewportNowPlayingPresented, isNowPlayingPresented)
        .environment(\.dismissViewportNowPlaying, dismissNowPlaying)
        .environment(\.isSoftwareKeyboardVisible, isSoftwareKeyboardVisible)
        .environment(\.artworkDetailBackgroundContinuity, artworkDetailBackgroundContinuity)
        .environment(\.artistDetailArtworkContinuity, artistDetailArtworkContinuity)
        .environmentObject(navigationCoordinator)
        .accentColor(settingsManager.accentColor.color)
        .onAppear {
            NavigationCoordinator.setActiveSceneCoordinator(navigationCoordinator)
            NavigationCoordinator.setActiveAuxiliaryCommandCoordinator(navigationCoordinator)
            updateAppearance()
            DependencyContainer.shared.activeNowPlayingViewModel = nowPlayingVM
        }
        .onDisappear {
            NavigationCoordinator.clearActiveSceneCoordinator(navigationCoordinator)
            NavigationCoordinator.clearActiveAuxiliaryCommandCoordinator(navigationCoordinator)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                NavigationCoordinator.setActiveSceneCoordinator(navigationCoordinator)
                NavigationCoordinator.setActiveAuxiliaryCommandCoordinator(navigationCoordinator)
            }
        }
        .onChange(of: settingsManager.auroraVisualizationEnabled) { _ in
            updateAppearance()
        }
        .onReceive(powerStateMonitor.$isLowPowerMode) { newValue in
            isLowPowerMode = newValue
        }
        #if canImport(UIKit)
        .onReceive(Self.softwareKeyboardVisibilityPublisher) { newValue in
            if newValue != isSoftwareKeyboardVisible {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isSoftwareKeyboardVisible = newValue
                }
            }
        }
        #endif
        .rootNowPlayingPresentation(
            style: nowPlayingPresentationStyle,
            isPresented: $isNowPlayingPresented,
            onDismiss: completeNowPlayingDismissal
        ) {
            nowPlayingPresentationContent
        }
        .task {
            let deps = DependencyContainer.shared
            logRootTaskStart()
            deps.accountManager.loadAccounts()
            // Pre-populate server health states so tracks from unchecked servers
            // are dimmed until health checks confirm reachability.
            deps.serverHealthChecker.prepopulateUnknownStates()
            deps.syncCoordinator.refreshProviders()
            if deps.siriMediaIndexStore.loadIndex(maxAge: 3600) == nil,
               await deps.foregroundWorkScheduler.waitUntilAllowed(.systemMediaIndexing, policy: .idleOnly) {
                _ = await deps.siriMediaIndexStore.rebuildIndex()
            }
        }
        .macRootWindowMinimumFrame()
        .macViewportNowPlayingWindowChromeHidden(isNowPlayingPresented)
    }

    private func logRootTaskStart() {
        if let launchTime = EnsembleStartupTiming.launchTime {
            let elapsed = Date().timeIntervalSince(launchTime)
            EnsembleLogger.info("PERF_LAUNCH: rootView.task.start elapsed=\(String(format: "%.3f", elapsed))s")
        } else {
            EnsembleLogger.info("PERF_LAUNCH: rootView.task.start elapsed=unknown")
        }
    }

    #if canImport(UIKit)
    private static var softwareKeyboardVisibilityPublisher: AnyPublisher<Bool, Never> {
        Publishers.Merge(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
                .map { _ in true },
            NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)
                .map { _ in false }
        )
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
    #endif

    private func updateAppearance() {
        #if canImport(UIKit)
        if #available(iOS 16.0, *) {
            return
        }

        let tabBarAppearance = UITabBarAppearance()

        if settingsManager.auroraVisualizationEnabled {
            tabBarAppearance.configureWithTransparentBackground()
        } else {
            tabBarAppearance.configureWithDefaultBackground()
        }

        let navAppearance = UINavigationBarAppearance()
        if settingsManager.auroraVisualizationEnabled {
            navAppearance.configureWithTransparentBackground()
        } else {
            navAppearance.configureWithDefaultBackground()
        }

        // iOS 15 fix: scrollEdgeAppearance via appearance proxy doesn't reliably
        // apply, leaving tab bar/toolbar with no background. Explicitly set a blur
        // effect so content doesn't scroll behind chrome.
        let chromeRole = EnsembleDesign.Material.Role.sidebar
        let bgAlpha = chromeRole.chromeBackgroundAlpha(
            auroraEnabled: settingsManager.auroraVisualizationEnabled
        )
        let blurStyle = chromeRole.chromeBlurStyle

        navAppearance.backgroundEffect = UIBlurEffect(style: blurStyle)
        navAppearance.backgroundColor = .systemBackground.withAlphaComponent(bgAlpha)

        tabBarAppearance.backgroundEffect = UIBlurEffect(style: blurStyle)
        tabBarAppearance.backgroundColor = .systemBackground.withAlphaComponent(bgAlpha)

        let toolbarAppearance = UIToolbarAppearance()
        toolbarAppearance.backgroundEffect = UIBlurEffect(style: blurStyle)
        toolbarAppearance.backgroundColor = .systemBackground.withAlphaComponent(bgAlpha)
        UIToolbar.appearance().standardAppearance = toolbarAppearance
        UIToolbar.appearance().scrollEdgeAppearance = toolbarAppearance

        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
        #endif
    }

    @ViewBuilder
    private var mainContentView: some View {
        switch EnsemblePlatformFeaturePolicy.currentRootNavigationShell {
        case .sidebar:
            #if os(iOS)
            if #available(iOS 16.0, *) {
                SidebarView(
                    nowPlayingVM: nowPlayingVM,
                    selection: $sidebarSelection,
                    rootSidebarChromeRegistrationHandler: updateRootSidebarChromeRegistration
                )
            } else {
                MainTabView(nowPlayingVM: nowPlayingVM)
            }
            #elseif os(macOS)
            if #available(macOS 13.0, *) {
                SidebarView(
                    nowPlayingVM: nowPlayingVM,
                    selection: $sidebarSelection,
                    rootSidebarChromeRegistrationHandler: updateRootSidebarChromeRegistration
                )
            } else {
                MainTabView(nowPlayingVM: nowPlayingVM)
            }
            #else
            MainTabView(nowPlayingVM: nowPlayingVM)
            #endif
        case .tabs:
            MainTabView(nowPlayingVM: nowPlayingVM)
        }
    }

    private func updateRootSidebarChromeRegistration(_ registration: RootSidebarChromeRegistration) {
        if rootSidebarChromeRegistration != registration {
            rootSidebarChromeRegistration = registration
        }
    }

    private var supportsViewportNowPlayingPresentation: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    private var usesFullScreenNowPlayingPresentation: Bool {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            return UIDevice.current.userInterfaceIdiom == .pad
        }
        return false
        #else
        return false
        #endif
    }

    private var nowPlayingPresentationStyle: RootNowPlayingPresentationStyle {
        if supportsViewportNowPlayingPresentation {
            return .none
        }
        return usesFullScreenNowPlayingPresentation ? .fullScreenCover : .sheet
    }

    private var usesSidebarRootNavigationShell: Bool {
        switch EnsemblePlatformFeaturePolicy.currentRootNavigationShell {
        case .sidebar:
            #if os(iOS)
            if #available(iOS 16.0, *) {
                return true
            }
            return false
            #elseif os(macOS)
            if #available(macOS 13.0, *) {
                return true
            }
            return false
            #else
            return false
            #endif
        case .tabs:
            return false
        }
    }

    private var nowPlayingPresentationContent: some View {
        NowPlayingSheetView(
            viewModel: nowPlayingVM,
            dismissAction: dismissNowPlaying
        )
        .accentColor(settingsManager.accentColor.color)
        .environment(\.dismissViewportNowPlaying, dismissNowPlaying)
        .environmentObject(navigationCoordinator)
    }

    private func presentNowPlayingFromMiniPlayer() {
        let scheduler = DependencyContainer.shared.foregroundWorkScheduler
        scheduler.beginInteraction(.nowPlayingInteractive)
        withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.9)) {
            isNowPlayingPresented = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            scheduler.endInteraction(.nowPlayingInteractive)
        }
    }

    private func dismissNowPlaying() {
        let scheduler = DependencyContainer.shared.foregroundWorkScheduler
        scheduler.beginInteraction(.nowPlayingInteractive)
        withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.9)) {
            isNowPlayingPresented = false
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            scheduler.endInteraction(.nowPlayingInteractive)
        }
        if supportsViewportNowPlayingPresentation {
            completeNowPlayingDismissal()
        }
    }

    private func completeNowPlayingDismissal() {
        guard let pending = navigationCoordinator.pendingNavigation else { return }
        navigationCoordinator.pendingNavigation = nil

        let targetTab: TabItem
        if usesSidebarRootNavigationShell {
            sidebarSelection = SidebarSelection.selection(
                for: pending.destination,
                fallback: sidebarSelection
            )
            targetTab = NavigationCoordinator.targetTab(for: pending.destination)
        } else {
            targetTab = pending.tab
        }

        navigationCoordinator.selectedTab = targetTab
        navigationCoordinator.push(pending.destination, in: targetTab)
    }
}

private extension View {
    @ViewBuilder
    func macRootWindowMinimumFrame() -> some View {
        #if os(macOS)
        self.frame(
            minWidth: EnsembleScaffold.RootWindow.macMinimumWidth,
            minHeight: EnsembleScaffold.RootWindow.macMinimumHeight
        )
        #else
        self
        #endif
    }

    @ViewBuilder
    func macViewportNowPlayingWindowChromeHidden(_ isHidden: Bool) -> some View {
        #if os(macOS)
        self.background(
            MacWindowNowPlayingChromeBridge(
                isHidden: isHidden
            )
        )
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct MacWindowNowPlayingChromeBridge: NSViewRepresentable {
    let isHidden: Bool

    func makeNSView(context: Context) -> NowPlayingChromeProbeView {
        let view = NowPlayingChromeProbeView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: NowPlayingChromeProbeView, context: Context) {
        nsView.isToolbarHidden = isHidden
        nsView.applyWindowChrome()
    }

    final class NowPlayingChromeProbeView: NSView {
        var isToolbarHidden = false
        private weak var appliedWindow: NSWindow?
        private var didCaptureOriginalChrome = false
        private var originalTitle: String?
        private var originalStyleMask: NSWindow.StyleMask?
        private var originalTitleVisibility: NSWindow.TitleVisibility?
        private var originalTitlebarAppearsTransparent: Bool?
        private var originalTitlebarSeparatorStyle: NSTitlebarSeparatorStyle?
        private var originalToolbarStyle: NSWindow.ToolbarStyle?
        private var originalToolbarBaselineSeparatorVisibility: Bool?
        private var originalToolbarChromeViewVisibility: [ObjectIdentifier: (view: NSView, isHidden: Bool)] = [:]
        private var isReapplyScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            if let appliedWindow, appliedWindow !== window {
                restoreAppliedWindowIfNeeded()
                self.appliedWindow = nil
            }

            applyWindowChrome()
        }

        func applyWindowChrome() {
            guard let window else {
                restoreAppliedWindowIfNeeded()
                return
            }

            if appliedWindow !== window {
                restoreAppliedWindowIfNeeded()
                appliedWindow = window
            }

            if isToolbarHidden {
                applyNowPlayingChrome(on: window)
            } else {
                restoreWindowChrome(on: window)
            }
        }

        override func removeFromSuperview() {
            restoreAppliedWindowIfNeeded()
            super.removeFromSuperview()
        }

        deinit {
            restoreAppliedWindowIfNeeded()
        }

        private func restoreAppliedWindowIfNeeded() {
            guard let appliedWindow else { return }
            restoreWindowChrome(on: appliedWindow)
            self.appliedWindow = nil
        }

        private func applyNowPlayingChrome(on window: NSWindow) {
            captureOriginalChromeIfNeeded(from: window)
            applyHiddenTitlebarChrome(on: window)
            setToolbarChromeHidden(true, on: window)

            validateWindowButtons(on: window)
            scheduleToolbarReapplyIfNeeded(for: window)
        }

        private func applyHiddenTitlebarChrome(on window: NSWindow) {
            window.title = ""
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }

        private func captureOriginalChromeIfNeeded(from window: NSWindow) {
            guard !didCaptureOriginalChrome else { return }

            didCaptureOriginalChrome = true
            originalTitle = window.title
            originalStyleMask = window.styleMask
            originalTitleVisibility = window.titleVisibility
            originalTitlebarAppearsTransparent = window.titlebarAppearsTransparent
            originalTitlebarSeparatorStyle = window.titlebarSeparatorStyle
            originalToolbarStyle = window.toolbarStyle
        }

        private func restoreWindowChrome(on window: NSWindow) {
            guard didCaptureOriginalChrome else { return }

            restoreToolbarItems(on: window.toolbar)

            if let originalTitle {
                window.title = originalTitle
            }

            if let originalStyleMask {
                window.styleMask = originalStyleMask
            }

            if let originalTitleVisibility {
                window.titleVisibility = originalTitleVisibility
            }

            if let originalTitlebarAppearsTransparent {
                window.titlebarAppearsTransparent = originalTitlebarAppearsTransparent
            }

            if let originalTitlebarSeparatorStyle {
                window.titlebarSeparatorStyle = originalTitlebarSeparatorStyle
            }

            if let originalToolbarStyle {
                window.toolbarStyle = originalToolbarStyle
            }

            didCaptureOriginalChrome = false
            originalTitle = nil
            originalStyleMask = nil
            originalTitleVisibility = nil
            originalTitlebarAppearsTransparent = nil
            originalTitlebarSeparatorStyle = nil
            originalToolbarStyle = nil
            isReapplyScheduled = false
        }

        private func scheduleToolbarReapplyIfNeeded(for window: NSWindow) {
            guard !isReapplyScheduled else { return }
            isReapplyScheduled = true

            DispatchQueue.main.async { [weak self, weak window] in
                guard let self else { return }
                self.isReapplyScheduled = false
                guard self.isToolbarHidden,
                      let window,
                      self.appliedWindow === window else {
                    return
                }

                self.applyHiddenTitlebarChrome(on: window)
                self.setToolbarChromeHidden(true, on: window)
                self.validateWindowButtons(on: window)
            }
        }

        private func setToolbarChromeHidden(_ isHidden: Bool, on window: NSWindow) {
            guard let toolbar = window.toolbar else { return }

            if originalToolbarBaselineSeparatorVisibility == nil {
                originalToolbarBaselineSeparatorVisibility = toolbar.showsBaselineSeparator
            }
            toolbar.showsBaselineSeparator = !isHidden

            let protectedWindowButtons = protectedWindowButtonIdentifiers(in: window)

            toolbar.visibleItems?.forEach { item in
                toolbarChromeViews(for: item).forEach { chromeView in
                    guard !protectedWindowButtons.contains(ObjectIdentifier(chromeView)) else { return }
                    setToolbarChromeView(chromeView, hidden: isHidden)
                }
            }

            setTitlebarHostChromeHidden(
                isHidden,
                in: window,
                protectedWindowButtons: protectedWindowButtons
            )
        }

        private func protectedWindowButtonIdentifiers(in window: NSWindow) -> Set<ObjectIdentifier> {
            Set(
                [
                    window.standardWindowButton(.closeButton),
                    window.standardWindowButton(.miniaturizeButton),
                    window.standardWindowButton(.zoomButton)
                ]
                .compactMap { $0 }
                .map(ObjectIdentifier.init)
            )
        }

        private func toolbarChromeViews(for item: NSToolbarItem) -> [NSView] {
            guard let itemView = item.view else { return [] }

            var views = [itemView]
            var candidateView = itemView.superview

            while let candidate = candidateView {
                let className = NSStringFromClass(type(of: candidate))
                let superviewClassName = candidate.superview.map { NSStringFromClass(type(of: $0)) } ?? ""

                if className.contains("ToolbarItem") ||
                    className.contains("NSToolbarItem") ||
                    superviewClassName.contains("ToolbarView") {
                    views.append(candidate)
                    break
                }

                candidateView = candidate.superview
            }

            return views
        }

        private func setTitlebarHostChromeHidden(
            _ isHidden: Bool,
            in window: NSWindow,
            protectedWindowButtons: Set<ObjectIdentifier>
        ) {
            guard let themeFrame = window.contentView?.superview else { return }
            themeFrame.allDescendants().forEach { view in
                guard !protectedWindowButtons.contains(ObjectIdentifier(view)),
                      shouldHideTitlebarHostChrome(view) else {
                    return
                }

                setToolbarChromeView(view, hidden: isHidden)
            }
        }

        private func shouldHideTitlebarHostChrome(_ view: NSView) -> Bool {
            guard isInsideTitlebarContainer(view) else { return false }

            let className = NSStringFromClass(type(of: view))
            let layerClassName = view.layer.map { NSStringFromClass(type(of: $0)) } ?? ""

            return className.contains("NSToolbarView") ||
                className.contains("NSGlassContainerView") ||
                className.contains("NSToolbarPlatterView") ||
                className.contains("NSGlassEffectView") ||
                className.contains("_NSTitlebarDecorationView") ||
                className.contains("NSTitlebarContainerBlockingView") ||
                layerClassName.contains("CABackdropLayer")
        }

        private func isInsideTitlebarContainer(_ view: NSView) -> Bool {
            var candidateView = view.superview
            while let candidate = candidateView {
                if NSStringFromClass(type(of: candidate)).contains("NSTitlebarContainerView") {
                    return true
                }
                candidateView = candidate.superview
            }
            return false
        }

        private func setToolbarChromeView(_ view: NSView, hidden: Bool) {
            let identifier = ObjectIdentifier(view)
            if originalToolbarChromeViewVisibility[identifier] == nil {
                originalToolbarChromeViewVisibility[identifier] = (view, view.isHidden)
            }
            view.isHidden = hidden
        }

        private func restoreToolbarItems(on toolbar: NSToolbar?) {
            if let originalToolbarBaselineSeparatorVisibility {
                toolbar?.showsBaselineSeparator = originalToolbarBaselineSeparatorVisibility
                self.originalToolbarBaselineSeparatorVisibility = nil
            }

            for (_, visibility) in originalToolbarChromeViewVisibility {
                visibility.view.isHidden = visibility.isHidden
            }
            originalToolbarChromeViewVisibility.removeAll()
        }

        private func validateWindowButtons(on window: NSWindow) {
            #if DEBUG
            let buttonTypes: [NSWindow.ButtonType] = [
                .closeButton,
                .miniaturizeButton,
                .zoomButton
            ]

            for buttonType in buttonTypes {
                guard let button = window.standardWindowButton(buttonType), !button.isHidden else {
                    EnsembleLogger.debug("[NowPlayingChrome] Missing or hidden standard window button: \(buttonType.rawValue)")
                    continue
                }
            }
            #endif
        }
    }
}

private extension NSView {
    func allDescendants() -> [NSView] {
        subviews + subviews.flatMap { $0.allDescendants() }
    }
}
#endif
