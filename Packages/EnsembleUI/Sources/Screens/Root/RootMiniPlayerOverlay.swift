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

    var body: some View {
        let miniPlayerWidth = min(620, max(layout.frame.width - 28, 0))
        let usesExpandedLayout = miniPlayerWidth >= 500

        if layout.showsMiniPlayer && layout.hasRenderableFrame && miniPlayerWidth > 0 {
            MiniPlayer(
                viewModel: nowPlayingVM,
                isFloating: true,
                showsWaveform: usesExpandedLayout,
                waveformColor: .accentColor,
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
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ToastBottomLimitPreference.self,
                        value: geometry.frame(in: .global).minY
                    )
                }
            }
            .frame(
                width: layout.frame.width,
                height: max(0, layout.frame.maxY - layout.bottomPadding),
                alignment: .bottom
            )
            .offset(x: layout.frame.minX + layout.horizontalOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .transition(.identity)
        }
    }
}
