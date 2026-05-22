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
            CrossfadingBlurredArtworkBackground(
                image: displayedImage,
                topDimming: colorScheme == .dark ? 0.1 : 0.05,
                bottomDimming: colorScheme == .dark ? 0.4 : 0.3,
                overlayColor: backgroundOverlayColor,
                isEnabled: usesNavigationContinuity
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

private struct CrossfadingBlurredArtworkBackground: View {
    let image: PlatformImage?
    let topDimming: Double
    let bottomDimming: Double
    let overlayColor: Color
    let isEnabled: Bool

    @State private var currentImage: PlatformImage?
    @State private var previousImage: PlatformImage?
    @State private var currentOpacity = 1.0
    @State private var transitionID = UUID()

    init(
        image: PlatformImage?,
        topDimming: Double,
        bottomDimming: Double,
        overlayColor: Color,
        isEnabled: Bool
    ) {
        self.image = image
        self.topDimming = topDimming
        self.bottomDimming = bottomDimming
        self.overlayColor = overlayColor
        self.isEnabled = isEnabled
        self._currentImage = State(initialValue: image)
    }

    var body: some View {
        ZStack {
            if isEnabled, let previousImage {
                blurredBackground(image: previousImage)
            }

            blurredBackground(image: currentImage ?? image)
                .opacity(currentOpacity)
        }
        .task(id: imageIdentity) {
            await updateImage()
        }
    }

    private var imageIdentity: ObjectIdentifier? {
        image.map(ObjectIdentifier.init)
    }

    private func blurredBackground(image: PlatformImage?) -> some View {
        BlurredArtworkBackground(
            image: image,
            topDimming: topDimming,
            bottomDimming: bottomDimming,
            overlayColor: overlayColor,
            animatesImageChanges: false
        )
    }

    @MainActor
    private func updateImage() async {
        guard isEnabled else {
            currentImage = image
            previousImage = nil
            currentOpacity = 1
            return
        }

        guard currentImage.map(ObjectIdentifier.init) != imageIdentity else {
            return
        }

        guard let image else {
            return
        }

        let transitionID = UUID()
        self.transitionID = transitionID
        previousImage = currentImage
        currentImage = image
        currentOpacity = previousImage == nil ? 1 : 0

        guard previousImage != nil else {
            return
        }

        await Task.yield()

        withAnimation(.easeInOut(duration: EnsembleScaffold.DetailSurface.backgroundFadeDuration)) {
            currentOpacity = 1
        }

        let delay = UInt64(EnsembleScaffold.DetailSurface.backgroundFadeDuration * 1_000_000_000)
        try? await Task.sleep(nanoseconds: delay)

        guard !Task.isCancelled, self.transitionID == transitionID else {
            return
        }
        previousImage = nil
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
