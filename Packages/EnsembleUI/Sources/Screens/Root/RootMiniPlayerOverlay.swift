import EnsembleCore
import SwiftUI

struct RootMiniPlayerOverlay: View {
    let nowPlayingVM: NowPlayingViewModel
    let layout: RootChromeLayout
    let accentColor: Color
    let namespace: Namespace.ID?
    let animationID: String
    var surfaceStyle: MiniPlayer.SurfaceStyle = .automatic
    let presentNowPlaying: () -> Void

    private var miniPlayerHeight: CGFloat {
        max(
            EnsembleScaffold.MiniPlayer.artworkDimension,
            EnsembleScaffold.MiniPlayer.largeRowMinimumHeight
        ) + (TrackListLayoutMetrics.rowVerticalPadding * 2)
    }

    var body: some View {
        let miniPlayerWidth = min(620, max(layout.frame.width - 28, 0))
        let usesExpandedLayout = miniPlayerWidth >= 500
        let miniPlayerPosition = miniPlayerPosition(
            for: layout,
            miniPlayerHeight: miniPlayerHeight
        )

        if layout.showsMiniPlayer && layout.hasRenderableFrame && miniPlayerWidth > 0 {
            MiniPlayer(
                viewModel: nowPlayingVM,
                isFloating: true,
                showsWaveform: usesExpandedLayout,
                waveformColor: accentColor,
                horizontalPadding: usesExpandedLayout ? 20 : 8,
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
