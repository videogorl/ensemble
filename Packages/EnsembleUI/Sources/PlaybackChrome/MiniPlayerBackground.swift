import EnsembleCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Handcrafted material background used on iOS 15-25. Owns artwork observation
/// so blur and material changes do not force the full MiniPlayer body to re-render.
struct MiniPlayerBackground: View {
    @ObservedObject var artworkProjection: NowPlayingArtworkProjection
    let pillCornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    private let materialRole = EnsembleScaffold.MiniPlayer.materialRole

    var body: some View {
        ZStack {
            if artworkProjection.currentTrack != nil {
                BlurredArtworkBackground(
                    image: artworkProjection.artworkImage,
                    preBlurredImage: artworkProjection.blurredArtworkImage,
                    blurRadius: EnsembleScaffold.MiniPlayer.backgroundBlurRadius,
                    contrast: EnsembleScaffold.MiniPlayer.backgroundContrast,
                    saturation: EnsembleScaffold.MiniPlayer.backgroundSaturation,
                    brightness: colorScheme == .dark ? EnsembleScaffold.MiniPlayer.backgroundDarkBrightness : EnsembleScaffold.MiniPlayer.backgroundLightBrightness,
                    opacity: EnsembleScaffold.MiniPlayer.backgroundOpacity,
                    topDimming: EnsembleScaffold.MiniPlayer.backgroundTopDimming,
                    bottomDimming: EnsembleScaffold.MiniPlayer.backgroundBottomDimming,
                    shouldIgnoreSafeArea: false,
                    overlayColor: colorScheme == .dark ? .black : platformBackgroundColor
                )
                .animation(.easeInOut(duration: EnsembleScaffold.MiniPlayer.backgroundAnimationDuration), value: artworkProjection.artworkImage)
                .clipped()
                .allowsHitTesting(false)
            }

            RoundedRectangle(cornerRadius: pillCornerRadius)
                .fill(materialRole.fallbackMaterial)
                .overlay(surfaceSheen)
                .overlay(edgeGlow)
        }
    }

    private var platformBackgroundColor: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    private var surfaceSheen: some View {
        RoundedRectangle(cornerRadius: pillCornerRadius)
            .fill(
                LinearGradient(
                    colors: [
                        .primary.opacity(colorScheme == .dark ? EnsembleScaffold.MiniPlayer.sheenDarkTopOpacity : EnsembleScaffold.MiniPlayer.sheenLightOpacity),
                        .clear,
                        .primary.opacity(colorScheme == .dark ? EnsembleScaffold.MiniPlayer.sheenDarkBottomOpacity : EnsembleScaffold.MiniPlayer.sheenLightOpacity)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .allowsHitTesting(false)
    }

    private var edgeGlow: some View {
        RoundedRectangle(cornerRadius: pillCornerRadius)
            .fill(
                LinearGradient(
                    colors: [
                        .primary.opacity(colorScheme == .dark ? EnsembleScaffold.MiniPlayer.edgeGlowDarkOpacity : EnsembleScaffold.MiniPlayer.edgeGlowLightOpacity),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
            )
            .padding(EnsembleScaffold.MiniPlayer.edgeGlowInset)
            .mask(RoundedRectangle(cornerRadius: pillCornerRadius))
            .allowsHitTesting(false)
    }
}
