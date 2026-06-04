import EnsembleCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

enum RootNowPlayingPresentationStyle {
    case sheet
    case fullScreenCover
    case none
}

struct RootSceneLayerHost<Content: View>: View {
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    let playbackService: PlaybackServiceProtocol
    let accentColor: Color
    let isAuroraEnabled: Bool
    let isLowPowerMode: Bool
    let isNowPlayingPresented: Bool
    let isSoftwareKeyboardVisible: Bool
    let supportsViewportNowPlayingPresentation: Bool
    let namespace: Namespace.ID
    let animationID: String
    let presentNowPlaying: () -> Void
    let dismissNowPlaying: () -> Void
    let content: Content
    @State private var sidebarChromeRegistration: RootSidebarChromeRegistration = .hidden

    init(
        nowPlayingVM: NowPlayingViewModel,
        playbackService: PlaybackServiceProtocol,
        accentColor: Color,
        isAuroraEnabled: Bool,
        isLowPowerMode: Bool,
        isNowPlayingPresented: Bool,
        isSoftwareKeyboardVisible: Bool,
        supportsViewportNowPlayingPresentation: Bool,
        namespace: Namespace.ID,
        animationID: String,
        presentNowPlaying: @escaping () -> Void,
        dismissNowPlaying: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.nowPlayingVM = nowPlayingVM
        self.playbackService = playbackService
        self.accentColor = accentColor
        self.isAuroraEnabled = isAuroraEnabled
        self.isLowPowerMode = isLowPowerMode
        self.isNowPlayingPresented = isNowPlayingPresented
        self.isSoftwareKeyboardVisible = isSoftwareKeyboardVisible
        self.supportsViewportNowPlayingPresentation = supportsViewportNowPlayingPresentation
        self.namespace = namespace
        self.animationID = animationID
        self.presentNowPlaying = presentNowPlaying
        self.dismissNowPlaying = dismissNowPlaying
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                content
                    .zIndex(1)

                if isAuroraEnabled && !isNowPlayingPresented {
                    AuroraVisualizationView(
                        playbackService: playbackService,
                        consumer: .rootBackdrop,
                        accentColor: accentColor,
                        isLowPowerMode: isLowPowerMode,
                        activeContentMaxWidth: 670
                    )
                    .allowsHitTesting(false)
                    .zIndex(2)
                }

                if supportsViewportNowPlayingPresentation && isNowPlayingPresented {
                    NowPlayingViewportRoot(
                        viewModel: nowPlayingVM,
                        dismissAction: dismissNowPlaying
                    )
                    .accentColor(accentColor)
                    .transition(.opacity)
                    .zIndex(10)
                }
            }
            .coordinateSpace(name: RootChromeCoordinateSpace.name)
            .onPreferenceChange(RootSidebarChromeRegistrationPreferenceKey.self) { registration in
                sidebarChromeRegistration = registration
            }
            .overlayPreferenceValue(RootChromeRegistrationPreferenceKey.self) { registration in
                let layout = !isNowPlayingPresented && !isSoftwareKeyboardVisible
                    ? RootChromeLayoutResolver.resolve(
                        from: registration,
                        sidebarRegistration: sidebarChromeRegistration,
                        in: proxy
                    )
                    : .hidden

                rootMiniPlayerLayer(layout: layout)
            }
        }
    }

    @ViewBuilder
    private func rootMiniPlayerLayer(layout: RootChromeLayout) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            RootMiniPlayerWindowHost(
                nowPlayingVM: nowPlayingVM,
                layout: layout,
                accentColor: accentColor,
                animationID: animationID,
                navigationCoordinator: navigationCoordinator,
                presentNowPlaying: presentNowPlaying
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        } else if layout.showsMiniPlayer {
            RootMiniPlayerOverlay(
                nowPlayingVM: nowPlayingVM,
                layout: layout,
                accentColor: accentColor,
                namespace: namespace,
                animationID: animationID,
                presentNowPlaying: presentNowPlaying
            )
            .zIndex(5)
        }
        #else
        if layout.showsMiniPlayer {
            RootMiniPlayerOverlay(
                nowPlayingVM: nowPlayingVM,
                layout: layout,
                accentColor: accentColor,
                namespace: namespace,
                animationID: animationID,
                presentNowPlaying: presentNowPlaying
            )
            .zIndex(5)
        }
        #endif
    }
}

extension View {
    @ViewBuilder
    func rootNowPlayingPresentation<PresentationContent: View>(
        style: RootNowPlayingPresentationStyle,
        isPresented: Binding<Bool>,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> PresentationContent
    ) -> some View {
        #if os(iOS)
        switch style {
        case .sheet:
            sheet(
                isPresented: isPresented,
                onDismiss: onDismiss,
                content: content
            )
        case .fullScreenCover:
            fullScreenCover(
                isPresented: isPresented,
                onDismiss: onDismiss,
                content: content
            )
        case .none:
            self
        }
        #else
        self
        #endif
    }
}
