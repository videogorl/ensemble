import SwiftUI

/// Shared blurred-artwork header treatment used by media-style detail screens.
/// Keeping this in one place prevents dark/light mode overlay drift between
/// `MediaDetailView` and download detail surfaces.
struct ArtworkDetailBackground: View {
    let image: UIImage?
    let height: CGFloat
    let darkLegibilityOpacity: Double
    let lightLegibilityOpacity: Double

    @Environment(\.colorScheme) private var colorScheme

    init(
        image: UIImage?,
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
    }

    private var backgroundOverlayColor: Color {
        colorScheme == .dark ? .black : EnsembleDesign.Color.windowSurface
    }
}
