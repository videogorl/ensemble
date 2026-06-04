import EnsembleCore
import SwiftUI

final class ArtworkDetailBackgroundContinuityStore: ObservableObject {
    var lastImage: PlatformImage?
    var lastBlurredImage: PlatformImage?
    var lastIdentity: String?
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
    let preBlurredImage: PlatformImage?
    let preBlurredCacheKey: String?
    let height: CGFloat
    let darkLegibilityOpacity: Double
    let lightLegibilityOpacity: Double
    let usesNavigationContinuity: Bool
    let continuityIdentity: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.artworkDetailBackgroundContinuity) private var continuityStore
    @State private var continuityImage: PlatformImage?
    @State private var continuityBlurredImage: PlatformImage?

    init(
        image: PlatformImage?,
        preBlurredImage: PlatformImage? = nil,
        preBlurredCacheKey: String? = nil,
        height: CGFloat = 500,
        darkLegibilityOpacity: Double = EnsembleScaffold.DetailSurface.darkLegibilityOverlayOpacity,
        lightLegibilityOpacity: Double = EnsembleScaffold.DetailSurface.lightLegibilityOverlayOpacity,
        usesNavigationContinuity: Bool = false,
        continuityIdentity: String? = nil
    ) {
        self.image = image
        self.preBlurredImage = preBlurredImage
        self.preBlurredCacheKey = preBlurredCacheKey
        self.height = height
        self.darkLegibilityOpacity = darkLegibilityOpacity
        self.lightLegibilityOpacity = lightLegibilityOpacity
        self.usesNavigationContinuity = usesNavigationContinuity
        self.continuityIdentity = continuityIdentity
        self._continuityImage = State(initialValue: nil)
        self._continuityBlurredImage = State(initialValue: nil)
    }

    var body: some View {
        ZStack {
            BlurredArtworkBackground(
                image: displayedImage,
                preBlurredImage: displayedBlurredImage,
                preBlurredCacheKey: preBlurredCacheKey,
                topDimming: colorScheme == .dark ? 0.1 : 0.05,
                bottomDimming: colorScheme == .dark ? 0.4 : 0.3,
                overlayColor: backgroundOverlayColor,
                animatesImageChanges: false,
                fadesInDelayedImages: true
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
        .task(id: artworkStateIdentity) {
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
        guard continuityStore.lastIdentity == continuityIdentity else {
            return image
        }
        return continuityImage ?? continuityStore.lastImage ?? image
    }

    private var displayedBlurredImage: PlatformImage? {
        guard usesNavigationContinuity else {
            return preBlurredImage
        }
        guard continuityStore.lastIdentity == continuityIdentity else {
            return preBlurredImage
        }
        return preBlurredImage ?? continuityBlurredImage ?? continuityStore.lastBlurredImage
    }

    private var artworkStateIdentity: String {
        [
            continuityIdentity ?? "nil",
            image.map { "\(ObjectIdentifier($0).hashValue)" } ?? "no-image",
            preBlurredImage.map { "\(ObjectIdentifier($0).hashValue)" } ?? "no-blur"
        ].joined(separator: "|")
    }

    private func updateContinuityImage() {
        guard usesNavigationContinuity else {
            return
        }

        guard let continuityIdentity else {
            return
        }

        let canReuseCurrentIdentity = continuityStore.lastIdentity == continuityIdentity

        guard let image else {
            if continuityImage == nil, canReuseCurrentIdentity {
                continuityImage = continuityStore.lastImage
            }
            if continuityBlurredImage == nil, canReuseCurrentIdentity {
                continuityBlurredImage = continuityStore.lastBlurredImage
            }
            return
        }

        let previousImage = canReuseCurrentIdentity ? (continuityImage ?? continuityStore.lastImage) : nil
        if previousImage == nil {
            continuityImage = image
        } else if previousImage.map(ObjectIdentifier.init) != ObjectIdentifier(image) {
            continuityImage = image
        }

        if let preBlurredImage {
            let previousBlurredImage = canReuseCurrentIdentity ? (continuityBlurredImage ?? continuityStore.lastBlurredImage) : nil
            if previousBlurredImage == nil {
                continuityBlurredImage = preBlurredImage
            } else if previousBlurredImage.map(ObjectIdentifier.init) != ObjectIdentifier(preBlurredImage) {
                continuityBlurredImage = preBlurredImage
            }
            continuityStore.lastBlurredImage = preBlurredImage
        }

        continuityStore.lastImage = image
        continuityStore.lastIdentity = continuityIdentity
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
