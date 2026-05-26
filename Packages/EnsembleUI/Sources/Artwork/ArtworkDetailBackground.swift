import EnsembleCore
import SwiftUI

final class ArtworkDetailBackgroundContinuityStore: ObservableObject {
    var lastImage: PlatformImage?
}

private struct ArtworkDetailBackgroundContinuityKey: EnvironmentKey {
    static let defaultValue = ArtworkDetailBackgroundContinuityStore()
}

extension EnvironmentValues {
    var artworkDetailBackgroundContinuity: ArtworkDetailBackgroundContinuityStore {
        get { self[ArtworkDetailBackgroundContinuityKey.self] }
        set { self[ArtworkDetailBackgroundContinuityKey.self] = newValue }
    }
}

/// Shared blurred-artwork header treatment used by media-style detail screens.
/// Keeping this in one place prevents dark/light mode overlay drift between
/// `MediaDetailView` and download detail surfaces.
struct ArtworkDetailBackground: View {
    let image: PlatformImage?
    let height: CGFloat
    let darkLegibilityOpacity: Double
    let lightLegibilityOpacity: Double
    let usesNavigationContinuity: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.artworkDetailBackgroundContinuity) private var continuityStore
    @State private var continuityImage: PlatformImage?

    init(
        image: PlatformImage?,
        height: CGFloat = 500,
        darkLegibilityOpacity: Double = EnsembleScaffold.DetailSurface.darkLegibilityOverlayOpacity,
        lightLegibilityOpacity: Double = EnsembleScaffold.DetailSurface.lightLegibilityOverlayOpacity,
        usesNavigationContinuity: Bool = false
    ) {
        self.image = image
        self.height = height
        self.darkLegibilityOpacity = darkLegibilityOpacity
        self.lightLegibilityOpacity = lightLegibilityOpacity
        self.usesNavigationContinuity = usesNavigationContinuity
        self._continuityImage = State(initialValue: nil)
    }

    var body: some View {
        ZStack {
            BlurredArtworkBackground(
                image: displayedImage,
                topDimming: colorScheme == .dark ? 0.1 : 0.05,
                bottomDimming: colorScheme == .dark ? 0.4 : 0.3,
                overlayColor: backgroundOverlayColor,
                animatesImageChanges: false
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
        .artworkBackgroundExtensionEffect()
        .task(id: imageIdentity) {
            updateContinuityImage()
        }
    }

    private var backgroundOverlayColor: Color {
        colorScheme == .dark ? .black : EnsembleDesign.Color.windowSurface
    }

    private var displayedImage: PlatformImage? {
        guard usesNavigationContinuity else {
            return image
        }
        return continuityImage ?? continuityStore.lastImage ?? image
    }

    private var imageIdentity: ObjectIdentifier? {
        image.map(ObjectIdentifier.init)
    }

    private func updateContinuityImage() {
        guard usesNavigationContinuity else {
            return
        }

        guard let image else {
            if continuityImage == nil {
                continuityImage = continuityStore.lastImage
            }
            return
        }

        let previousImage = continuityImage ?? continuityStore.lastImage
        if previousImage == nil {
            continuityImage = image
        } else if previousImage.map(ObjectIdentifier.init) != ObjectIdentifier(image) {
            continuityImage = image
        }
        continuityStore.lastImage = image
    }
}

private extension View {
    @ViewBuilder
    func artworkBackgroundExtensionEffect() -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            self.backgroundExtensionEffect()
        } else {
            self
        }
        #else
        self
        #endif
    }
}
