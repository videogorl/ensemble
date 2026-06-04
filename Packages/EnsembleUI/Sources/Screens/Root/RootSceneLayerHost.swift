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
    let supportsViewportNowPlayingPresentation: Bool
    let namespace: Namespace.ID
    let animationID: String
    let presentNowPlaying: () -> Void
    let dismissNowPlaying: () -> Void
    let content: Content

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
            .overlayPreferenceValue(RootChromeRegistrationPreferenceKey.self) { registration in
                if !isNowPlayingPresented && !isSoftwareKeyboardVisible {
                    RootMiniPlayerOverlay(
                        nowPlayingVM: nowPlayingVM,
                        layout: RootChromeLayoutResolver.resolve(from: registration, in: proxy),
                        accentColor: accentColor,
                        namespace: namespace,
                        animationID: animationID,
                        presentNowPlaying: presentNowPlaying
                    )
                    .zIndex(5)
                }
            }
        }
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
