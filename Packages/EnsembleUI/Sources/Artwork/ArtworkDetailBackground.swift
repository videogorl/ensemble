import EnsembleCore
import SwiftUI

/// Shared blurred-artwork header treatment used by media-style detail screens.
/// Keeping this in one place prevents dark/light mode overlay drift between
/// `MediaDetailView` and download detail surfaces.
struct ArtworkDetailBackground: View {
    let image: PlatformImage?
    let height: CGFloat
    let darkLegibilityOpacity: Double
    let lightLegibilityOpacity: Double

    @Environment(\.colorScheme) private var colorScheme

    init(
        image: PlatformImage?,
        height: CGFloat = 500,
        darkLegibilityOpacity: Double = EnsembleScaffold.DetailSurface.darkLegibilityOverlayOpacity,
        lightLegibilityOpacity: Double = EnsembleScaffold.DetailSurface.lightLegibilityOverlayOpacity
    ) {
        self.image = image
        self.height = height
        self.darkLegibilityOpacity = darkLegibilityOpacity
        self.lightLegibilityOpacity = lightLegibilityOpacity
    }

    var body: some View {
        ZStack {
            BlurredArtworkBackground(
                image: image,
                topDimming: colorScheme == .dark ? 0.1 : 0.05,
                bottomDimming: colorScheme == .dark ? 0.4 : 0.3,
                overlayColor: backgroundOverlayColor
            )
            .id(backgroundImageIdentity)
            .transition(.opacity)

            // Keep the same legibility wash used by MediaDetailView across all
            // detail-style screens so the artwork glow remains visible.
            if colorScheme == .dark {
                Color.black.opacity(darkLegibilityOpacity)
                    .allowsHitTesting(false)
            } else {
                backgroundOverlayColor.opacity(lightLegibilityOpacity)
                    .allowsHitTesting(false)
            }
        }
        .mask(
            LinearGradient(
                colors: [.white, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(height: height)
        .animation(
            .easeInOut(duration: EnsembleScaffold.DetailSurface.backgroundFadeDuration),
            value: backgroundImageIdentity
        )
    }

    private var backgroundOverlayColor: Color {
        colorScheme == .dark ? .black : EnsembleDesign.Color.windowSurface
    }

    private var backgroundImageIdentity: ObjectIdentifier? {
        image.map(ObjectIdentifier.init)
    }
}
