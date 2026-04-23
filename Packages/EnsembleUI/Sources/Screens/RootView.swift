import Combine
import EnsembleCore
import SwiftUI
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

enum RootChromeCoordinateSpace {
    static let name = "RootChromeCoordinateSpace"
}

struct RootChromeRegistration {
    let bounds: Anchor<CGRect>?
    let bottomPadding: CGFloat
    let showsMiniPlayer: Bool
    let priority: Int

    static let hidden = RootChromeRegistration(
        bounds: nil,
        bottomPadding: 0,
        showsMiniPlayer: false,
        priority: .min
    )
}

struct RootChromeLayout: Equatable {
    let frame: CGRect
    let bottomPadding: CGFloat
    let showsMiniPlayer: Bool

    static let hidden = RootChromeLayout(
        frame: .zero,
        bottomPadding: 0,
        showsMiniPlayer: false
    )

    var hasRenderableFrame: Bool {
        frame.width > 0 && frame.height > 0
    }
}

private struct RootChromeRegistrationPreferenceKey: PreferenceKey {
    static var defaultValue: RootChromeRegistration = .hidden

    static func reduce(value: inout RootChromeRegistration, nextValue: () -> RootChromeRegistration) {
        let next = nextValue()
        if next.priority >= value.priority {
            value = next
        }
    }
}

struct RootChromeFrameRegistrationView: View {
    let bottomPadding: CGFloat
    let showsMiniPlayer: Bool
    let priority: Int

    var body: some View {
        Color.clear.anchorPreference(
            key: RootChromeRegistrationPreferenceKey.self,
            value: .bounds
        ) { bounds in
            RootChromeRegistration(
                bounds: bounds,
                bottomPadding: bottomPadding,
                showsMiniPlayer: showsMiniPlayer,
                priority: priority
            )
        }
    }
}

private struct RootMiniPlayerOverlay: View {
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let layout: RootChromeLayout
    let accentColor: Color
    let namespace: Namespace.ID
    let animationID: String
    let presentNowPlaying: () -> Void

    private var isPhoneLayout: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var miniPlayerHorizontalPadding: CGFloat {
        isPhoneLayout ? 8 : 20
    }

    private var miniPlayerWidth: CGFloat {
        if isPhoneLayout {
            // Keep the mini player aligned to the tab bar capsule while leaving
            // just enough extra width to avoid looking visually under-hung.
            return max(layout.frame.width - 28, 0)
        }
        return min(620, max(layout.frame.width - 32, 0))
    }

    var body: some View {
        if layout.showsMiniPlayer && layout.hasRenderableFrame && miniPlayerWidth > 0 {
            MiniPlayer(
                viewModel: nowPlayingVM,
                isFloating: true,
                showsWaveform: !isPhoneLayout && miniPlayerWidth >= 280,
                waveformColor: accentColor,
                horizontalPadding: miniPlayerHorizontalPadding,
                namespace: namespace,
                animationID: animationID
            ) {
                withAnimation(.interactiveSpring(response: 0.45, dampingFraction: 0.85)) {
                    presentNowPlaying()
                }
            }
            .accentColor(accentColor)
            .frame(width: miniPlayerWidth)
            .padding(.bottom, layout.bottomPadding)
            .frame(
                width: layout.frame.width,
                height: layout.frame.height,
                alignment: .bottom
            )
            .offset(x: layout.frame.minX, y: layout.frame.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.identity)
        }
    }
}

private struct RootMiniPlayerOverlayHost: View {
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let currentLayout: RootChromeLayout
    let accentColor: Color
    let namespace: Namespace.ID
    let animationID: String
    let presentNowPlaying: () -> Void

    @State private var retainedLayout: RootChromeLayout = .hidden

    private var effectiveLayout: RootChromeLayout {
        currentLayout.hasRenderableFrame ? currentLayout : retainedLayout
    }

    var body: some View {
        RootMiniPlayerOverlay(
            nowPlayingVM: nowPlayingVM,
            layout: effectiveLayout,
            accentColor: accentColor,
            namespace: namespace,
            animationID: animationID,
            presentNowPlaying: presentNowPlaying
        )
        .onAppear {
            captureLayoutIfNeeded(currentLayout)
        }
        .onChange(of: currentLayout) { newLayout in
            captureLayoutIfNeeded(newLayout)
        }
    }

    private func captureLayoutIfNeeded(_ layout: RootChromeLayout) {
        guard layout.hasRenderableFrame else {
            return
        }

        retainedLayout = layout
    }
}

/// Root view that renders the main content directly (no auth gate)
@available(iOS 15.0, macOS 12.0, watchOS 8.0, *)
public struct RootView: View {
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    private let powerStateMonitor = DependencyContainer.shared.powerStateMonitor
    @StateObject private var navigationCoordinator: NavigationCoordinator
    @StateObject private var nowPlayingVM: NowPlayingViewModel
    @State private var isNowPlayingPresented = false
    @State private var activeNowPlayingPresentationViewModel: NowPlayingViewModel?
    @State private var isLowPowerMode = DependencyContainer.shared.powerStateMonitor.isLowPowerMode
    @Namespace private var playerNamespace
    private let artworkAnimationID = "nowPlayingArtwork"

    private var auroraAboveContent: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
        #else
        true
        #endif
    }

    private var showsRootBackgroundAurora: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
        #else
        true
        #endif
    }

    public init() {
        let navigationCoordinator = NavigationCoordinator()
        _navigationCoordinator = StateObject(wrappedValue: navigationCoordinator)
        _nowPlayingVM = StateObject(
            wrappedValue: DependencyContainer.shared.makeNowPlayingViewModel(
                navigationCoordinator: navigationCoordinator
            )
        )
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                if settingsManager.auroraVisualizationEnabled &&
                    !isNowPlayingPresented &&
                    showsRootBackgroundAurora &&
                    !auroraAboveContent {
                    AuroraVisualizationView(
                        playbackService: DependencyContainer.shared.playbackService,
                        consumer: .rootBackdrop,
                        accentColor: settingsManager.accentColor.color,
                        isLowPowerMode: isLowPowerMode,
                        activeContentMaxWidth: 670
                    )
                    .allowsHitTesting(false)
                    .zIndex(0)
                }

                mainContentView
                    .zIndex(1)

                if settingsManager.auroraVisualizationEnabled && !isNowPlayingPresented && auroraAboveContent {
                    AuroraVisualizationView(
                        playbackService: DependencyContainer.shared.playbackService,
                        consumer: .rootBackdrop,
                        accentColor: settingsManager.accentColor.color,
                        isLowPowerMode: isLowPowerMode,
                        activeContentMaxWidth: 670
                    )
                    .allowsHitTesting(false)
                    .zIndex(2)
                }

                if supportsViewportNowPlayingPresentation && isNowPlayingPresented {
                    NowPlayingViewportRoot(
                        viewModel: presentedNowPlayingViewModel,
                        dismissAction: dismissNowPlaying
                    )
                    .accentColor(settingsManager.accentColor.color)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(10)
                }
            }
            .coordinateSpace(name: RootChromeCoordinateSpace.name)
            .overlayPreferenceValue(RootChromeRegistrationPreferenceKey.self) { registration in
                if !isNowPlayingPresented {
                    RootMiniPlayerOverlayHost(
                        nowPlayingVM: nowPlayingVM,
                        currentLayout: resolvedRootChromeLayout(from: registration, in: proxy),
                        accentColor: settingsManager.accentColor.color,
                        namespace: playerNamespace,
                        animationID: artworkAnimationID,
                        presentNowPlaying: presentNowPlayingFromMiniPlayer
                    )
                    .zIndex(5)
                }
            }
            .environment(\.isViewportNowPlayingPresented, isNowPlayingPresented)
            .environment(\.presentViewportNowPlaying, presentNowPlaying(with:))
            .environment(\.dismissViewportNowPlaying, dismissNowPlaying)
            .environmentObject(navigationCoordinator)
            .accentColor(settingsManager.accentColor.color)
            .onAppear {
                updateAppearance()
                DependencyContainer.shared.activeNowPlayingViewModel = nowPlayingVM
            }
            .onChange(of: settingsManager.accentColor) { _ in
                updateAppearance()
            }
            .onChange(of: settingsManager.auroraVisualizationEnabled) { _ in
                updateAppearance()
            }
            .onReceive(powerStateMonitor.$isLowPowerMode) { newValue in
                isLowPowerMode = newValue
            }
            .modifier(NowPlayingPresentationModifier(rootView: self))
            .task {
                let deps = DependencyContainer.shared
                deps.accountManager.loadAccounts()
                // Pre-populate server health states so tracks from unchecked servers
                // are dimmed until health checks confirm reachability.
                deps.serverHealthChecker.prepopulateUnknownStates()
                deps.syncCoordinator.refreshProviders()
                _ = await deps.siriMediaIndexStore.rebuildIndex()
            }
        }
    }

    private func updateAppearance() {
        #if canImport(UIKit) && !os(watchOS)
        let navAppearance = UINavigationBarAppearance()
        let tabBarAppearance = UITabBarAppearance()

        if settingsManager.auroraVisualizationEnabled {
            // Transparent backgrounds for aurora visibility
            navAppearance.configureWithTransparentBackground()
            tabBarAppearance.configureWithTransparentBackground()
        } else {
            // Default opaque backgrounds
            navAppearance.configureWithDefaultBackground()
            tabBarAppearance.configureWithDefaultBackground()
        }

        // iOS 15 fix: scrollEdgeAppearance via appearance proxy doesn't reliably
        // apply, leaving tab bar/toolbar with no background. Explicitly set a blur
        // effect so content doesn't scroll behind chrome.
        if #available(iOS 16.0, *) {
            // iOS 16+ handles this correctly — no extra work needed
        } else {
            let bgAlpha: CGFloat = settingsManager.auroraVisualizationEnabled ? 0.3 : 0.85
            let blurStyle: UIBlurEffect.Style = .systemChromeMaterial

            // Nav bar
            navAppearance.backgroundEffect = UIBlurEffect(style: blurStyle)
            navAppearance.backgroundColor = .systemBackground.withAlphaComponent(bgAlpha)

            // Tab bar
            tabBarAppearance.backgroundEffect = UIBlurEffect(style: blurStyle)
            tabBarAppearance.backgroundColor = .systemBackground.withAlphaComponent(bgAlpha)

            // Toolbar
            let toolbarAppearance = UIToolbarAppearance()
            toolbarAppearance.backgroundEffect = UIBlurEffect(style: blurStyle)
            toolbarAppearance.backgroundColor = .systemBackground.withAlphaComponent(bgAlpha)
            UIToolbar.appearance().standardAppearance = toolbarAppearance
            UIToolbar.appearance().scrollEdgeAppearance = toolbarAppearance
        }

        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance

        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
        #endif
    }

    @ViewBuilder
    private var mainContentView: some View {
        #if os(iOS)
        if #available(iOS 16.0, *), UIDevice.current.userInterfaceIdiom == .pad {
            SidebarView(nowPlayingVM: nowPlayingVM)
        } else {
            MainTabView(nowPlayingVM: nowPlayingVM)
        }
        #elseif os(macOS)
        if #available(macOS 13.0, *) {
            SidebarView(nowPlayingVM: nowPlayingVM)
        } else {
            MainTabView(nowPlayingVM: nowPlayingVM)
        }
        #else
        MainTabView(nowPlayingVM: nowPlayingVM)
        #endif
    }

    private var presentedNowPlayingViewModel: NowPlayingViewModel {
        activeNowPlayingPresentationViewModel ?? nowPlayingVM
    }

    private func resolvedRootChromeLayout(
        from registration: RootChromeRegistration,
        in proxy: GeometryProxy
    ) -> RootChromeLayout {
        let rootBounds = CGRect(origin: .zero, size: proxy.size)

        guard rootBounds.width > 0,
              rootBounds.height > 0,
              let bounds = registration.bounds else {
            return .hidden
        }

        let visibleFrame = proxy[bounds].intersection(rootBounds)

        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return .hidden
        }

        return RootChromeLayout(
            frame: visibleFrame,
            bottomPadding: registration.bottomPadding,
            showsMiniPlayer: registration.showsMiniPlayer
        )
    }

    fileprivate var supportsViewportNowPlayingPresentation: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    fileprivate var usesFullScreenNowPlayingPresentation: Bool {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            return UIDevice.current.userInterfaceIdiom == .pad
        }
        return false
        #else
        return false
        #endif
    }

    fileprivate var nowPlayingPresentationContent: some View {
        NowPlayingSheetView(
            viewModel: presentedNowPlayingViewModel,
            namespace: playerNamespace,
            animationID: artworkAnimationID,
            dismissAction: dismissNowPlaying
        )
        .accentColor(settingsManager.accentColor.color)
        .environment(\.dismissViewportNowPlaying, dismissNowPlaying)
        .environmentObject(navigationCoordinator)
    }

    fileprivate var nowPlayingPresentationBinding: Binding<Bool> {
        $isNowPlayingPresented
    }

    private func presentNowPlaying(with viewModel: NowPlayingViewModel) {
        activeNowPlayingPresentationViewModel = viewModel
        withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.9)) {
            isNowPlayingPresented = true
        }
    }

    private func presentNowPlayingFromMiniPlayer() {
        presentNowPlaying(with: nowPlayingVM)
    }

    private func dismissNowPlaying() {
        withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.9)) {
            isNowPlayingPresented = false
        }
    }

    fileprivate func clearPresentedNowPlayingViewModel() {
        activeNowPlayingPresentationViewModel = nil
    }
}

private struct NowPlayingPresentationModifier: ViewModifier {
    let rootView: RootView

    func body(content: Content) -> some View {
        #if os(iOS)
        if rootView.usesFullScreenNowPlayingPresentation {
            content.fullScreenCover(
                isPresented: rootView.nowPlayingPresentationBinding,
                onDismiss: rootView.clearPresentedNowPlayingViewModel
            ) {
                rootView.nowPlayingPresentationContent
            }
        } else if !rootView.supportsViewportNowPlayingPresentation {
            content.sheet(
                isPresented: rootView.nowPlayingPresentationBinding,
                onDismiss: rootView.clearPresentedNowPlayingViewModel
            ) {
                rootView.nowPlayingPresentationContent
            }
        } else {
            content
        }
        #else
        if !rootView.supportsViewportNowPlayingPresentation {
            content.sheet(
                isPresented: rootView.nowPlayingPresentationBinding,
                onDismiss: rootView.clearPresentedNowPlayingViewModel
            ) {
                rootView.nowPlayingPresentationContent
            }
        } else {
            content
        }
        #endif
    }
}
