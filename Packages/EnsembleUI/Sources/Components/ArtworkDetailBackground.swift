import SwiftUI

/// Shared blurred-artwork header treatment used by media-style detail screens.
/// Keeping this in one place prevents dark/light mode overlay drift between
/// `MediaDetailView` and download detail surfaces.
struct ArtworkDetailBackground: View {
    let image: UIImage?
    let height: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    init(image: UIImage?, height: CGFloat = 500) {
        self.image = image
        self.height = height
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
                Color.black.opacity(0.45)
                    .allowsHitTesting(false)
            } else {
                backgroundOverlayColor.opacity(0.7)
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
        #if os(iOS)
        return colorScheme == .dark ? .black : Color(UIColor.systemBackground)
        #else
        return colorScheme == .dark ? .black : Color(NSColor.windowBackgroundColor)
        #endif
    }
}
