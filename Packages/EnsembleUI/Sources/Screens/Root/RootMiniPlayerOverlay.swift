import EnsembleCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RootMiniPlayerOverlay: View {
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let layout: RootChromeLayout
    let accentColor: Color
    let namespace: Namespace.ID?
    let animationID: String
    var surfaceStyle: MiniPlayer.SurfaceStyle = .automatic
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

    private var miniPlayerHeight: CGFloat {
        max(
            EnsembleScaffold.MiniPlayer.artworkDimension,
            EnsembleScaffold.MiniPlayer.largeRowMinimumHeight
        ) + (TrackListLayoutMetrics.rowVerticalPadding * 2)
    }

    var body: some View {
        let miniPlayerWidth = miniPlayerWidth(for: layout)
        let miniPlayerPosition = miniPlayerPosition(
            for: layout,
            miniPlayerHeight: miniPlayerHeight
        )

        if layout.showsMiniPlayer && layout.hasRenderableFrame && miniPlayerWidth > 0 {
            MiniPlayer(
                viewModel: nowPlayingVM,
                isFloating: true,
                showsWaveform: !isPhoneLayout && miniPlayerWidth >= 280,
                waveformColor: accentColor,
                horizontalPadding: miniPlayerHorizontalPadding,
                surfaceStyle: surfaceStyle,
                usesGlassEffectIdentity: false,
                namespace: namespace,
                animationID: animationID
            ) {
                withAnimation(.interactiveSpring(response: 0.45, dampingFraction: 0.85)) {
                    presentNowPlaying()
                }
            }
            .accentColor(accentColor)
            .frame(width: miniPlayerWidth)
            .position(miniPlayerPosition)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .transition(.identity)
        }
    }

    private func miniPlayerWidth(for layout: RootChromeLayout) -> CGFloat {
        if isPhoneLayout {
            // Keep the mini player aligned to the tab bar capsule while leaving
            // just enough extra width to avoid looking visually under-hung.
            return max(layout.frame.width - 28, 0)
        }
        return min(620, max(layout.frame.width - 32, 0))
    }

    private func miniPlayerPosition(
        for layout: RootChromeLayout,
        miniPlayerHeight: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: layout.frame.midX + layout.horizontalOffset,
            y: layout.frame.maxY - layout.bottomPadding - (miniPlayerHeight / 2)
        )
    }

}
