import EnsembleCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RootMiniPlayerOverlay: View {
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
            .offset(x: layout.horizontalOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(rootChromeLayoutAnimation, value: layout.horizontalAnchor)
            .transition(.identity)
        }
    }

    private var rootChromeLayoutAnimation: Animation {
        .easeInOut(duration: 0.25)
    }
}
