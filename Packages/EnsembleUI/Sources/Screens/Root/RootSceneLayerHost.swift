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
    let playbackService: PlaybackServiceProtocol
    let accentColor: Color
    let isAuroraEnabled: Bool
    let isLowPowerMode: Bool
    let isNowPlayingPresented: Bool
    let isSoftwareKeyboardVisible: Bool
    let sidebarChromeRegistration: RootSidebarChromeRegistration
    let supportsViewportNowPlayingPresentation: Bool
    let namespace: Namespace.ID
    let animationID: String
    let presentNowPlaying: () -> Void
    let dismissNowPlaying: () -> Void
    let content: Content
    @State private var preferenceSidebarChromeRegistration: RootSidebarChromeRegistration = .hidden
    @State private var sidebarChromeRootSize: CGSize = .zero

    init(
        nowPlayingVM: NowPlayingViewModel,
        playbackService: PlaybackServiceProtocol,
        accentColor: Color,
        isAuroraEnabled: Bool,
        isLowPowerMode: Bool,
        isNowPlayingPresented: Bool,
        isSoftwareKeyboardVisible: Bool,
        sidebarChromeRegistration: RootSidebarChromeRegistration = .absent,
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
        self.sidebarChromeRegistration = sidebarChromeRegistration
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
                updateSidebarChromeRegistration(registration, rootSize: proxy.size)
            }
            .overlayPreferenceValue(RootChromeRegistrationPreferenceKey.self) { registration in
                let layout = rootMiniPlayerLayout(
                    registration: registration,
                    proxy: proxy
                )

                rootMiniPlayerLayer(layout: layout)
            }
        }
    }

    private func updateSidebarChromeRegistration(
        _ registration: RootSidebarChromeRegistration,
        rootSize: CGSize
    ) {
        let rootSizeChanged = !Self.sizesMatch(rootSize, sidebarChromeRootSize)
        let stabilized = RootSidebarChromeRegistration.stabilized(
            current: preferenceSidebarChromeRegistration,
            next: registration,
            rootSizeChanged: rootSizeChanged
        )

        if stabilized != preferenceSidebarChromeRegistration {
            preferenceSidebarChromeRegistration = stabilized
        }
        if rootSizeChanged {
            sidebarChromeRootSize = rootSize
        }
    }

    private static func sizesMatch(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
    }

    private func rootMiniPlayerLayout(
        registration: RootChromeRegistration,
        proxy: GeometryProxy
    ) -> RootChromeLayout {
        guard !isNowPlayingPresented,
              !isSoftwareKeyboardVisible else {
            return .hidden
        }

        let resolved = RootChromeLayoutResolver.resolve(
            from: registration,
            sidebarRegistration: effectiveSidebarChromeRegistration,
            in: proxy
        )

        if resolved.showsMiniPlayer,
           resolved.hasRenderableFrame {
            return resolved
        }

        guard registration.bounds == nil || registration.showsMiniPlayer else {
            return resolved
        }

        return RootChromeLayoutResolver.rootFallback(in: proxy)
    }

    @ViewBuilder
    private func rootMiniPlayerLayer(layout: RootChromeLayout) -> some View {
        if layout.showsMiniPlayer {
            RootMiniPlayerOverlay(
                nowPlayingVM: nowPlayingVM,
                layout: layout,
                accentColor: accentColor,
                namespace: miniPlayerNamespace,
                animationID: animationID,
                surfaceStyle: miniPlayerSurfaceStyle,
                presentNowPlaying: presentNowPlaying
            )
            .zIndex(5)
        }
    }

    private var miniPlayerNamespace: Namespace.ID? {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return nil
        }
        #endif
        return namespace
    }

    private var miniPlayerSurfaceStyle: MiniPlayer.SurfaceStyle {
        return .automatic
    }

    private var effectiveSidebarChromeRegistration: RootSidebarChromeRegistration {
        if sidebarChromeRegistration.isVisible {
            return sidebarChromeRegistration
        }

        if preferenceSidebarChromeRegistration.isVisible {
            return preferenceSidebarChromeRegistration
        }

        if preferenceSidebarChromeRegistration.isPresent {
            return .hidden
        }

        if sidebarChromeRegistration.isPresent {
            return sidebarChromeRegistration
        }

        return .absent
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
