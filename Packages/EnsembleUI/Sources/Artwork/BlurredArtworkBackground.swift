import EnsembleCore
import SwiftUI

/// A background view that uses a heavily blurred version of artwork.
///
/// The blur is always bitmap-backed. Callers can pass `preBlurredImage`; otherwise
/// the view generates and caches a pre-blurred bitmap before displaying it.
public struct BlurredArtworkBackground: View {
    let image: PlatformImage?
    let preBlurredImage: PlatformImage?
    let blurRadius: CGFloat
    let contrast: Double
    let saturation: Double
    let brightness: Double
    let opacity: Double
    let topDimming: Double
    let bottomDimming: Double
    let shouldIgnoreSafeArea: Bool
    let overlayColor: Color
    let animatesImageChanges: Bool
    @State private var cachedBlurredImage: PlatformImage?

    public init(
        image: PlatformImage?,
        preBlurredImage: PlatformImage? = nil,
        blurRadius: CGFloat = 80,
        contrast: Double = 2.0,
        saturation: Double = 1.9,
        brightness: Double = -0.05,
        opacity: Double = 1.0,
        topDimming: Double = 0.1,
        bottomDimming: Double = 0.5,
        shouldIgnoreSafeArea: Bool = true,
        overlayColor: Color = .black,
        animatesImageChanges: Bool = true
    ) {
        self.image = image
        self.preBlurredImage = preBlurredImage
        self.blurRadius = blurRadius
        self.contrast = contrast
        self.saturation = saturation
        self.brightness = brightness
        self.opacity = opacity
        self.topDimming = topDimming
        self.bottomDimming = bottomDimming
        self.shouldIgnoreSafeArea = shouldIgnoreSafeArea
        self.overlayColor = overlayColor
        self.animatesImageChanges = animatesImageChanges
    }
    
    public var body: some View {
        Group {
            if shouldIgnoreSafeArea {
                content.ignoresSafeArea()
            } else {
                content
            }
        }
        .task(id: blurSourceIdentity) {
            await updateCachedBlurredImage()
        }
    }
    
    private var content: some View {
        GeometryReader { geometry in
            ZStack {
                // Guard against zero-sized geometry during layout/animation passes.
                // Artwork blur is always bitmap-backed: either supplied by the caller
                // or generated once through ArtworkBlurRenderer and cached.
                let displayImage = preBlurredImage ?? cachedBlurredImage

                if let displayImage = displayImage, geometry.size.width > 0, geometry.size.height > 0 {
                    #if os(macOS)
                    Image(nsImage: displayImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .opacity(opacity)
                        .optionalArtworkTransition(
                            id: image.map(ObjectIdentifier.init),
                            isEnabled: animatesImageChanges
                        )
                    #else
                    Image(uiImage: displayImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .opacity(opacity)
                        .optionalArtworkTransition(
                            id: image.map(ObjectIdentifier.init),
                            isEnabled: animatesImageChanges
                        )
                    #endif

                    // Dimming gradient to ensure controls are visible
                    LinearGradient(
                        stops: [
                            .init(color: overlayColor.opacity(topDimming), location: 0),
                            .init(color: overlayColor.opacity(topDimming * 0.5), location: 0.4),
                            .init(color: overlayColor.opacity(bottomDimming * 0.7), location: 0.7),
                            .init(color: overlayColor.opacity(bottomDimming), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    overlayColor
                }
            }
            .clipped()
        }
    }

    private var blurSourceIdentity: String {
        if let preBlurredImage {
            return "pre:\(ObjectIdentifier(preBlurredImage).hashValue)"
        }
        return image.map { "source:\(ObjectIdentifier($0).hashValue)" } ?? "nil"
    }

    @MainActor
    private func updateCachedBlurredImage() async {
        if let preBlurredImage {
            cachedBlurredImage = preBlurredImage
            return
        }

        guard let image else {
            cachedBlurredImage = nil
            return
        }

        if let cached = ArtworkBlurRenderer.cachedBlurredImage(for: image) {
            cachedBlurredImage = cached
            return
        }

        let sourceIdentity = ObjectIdentifier(image)
        let sendableImage = SendablePlatformImage(image)
        let blurred = await Task.detached(priority: .utility) {
            ArtworkBlurRenderer.blurredImage(from: sendableImage.value)
                .map(SendablePlatformImage.init)
        }.value

        guard !Task.isCancelled, ObjectIdentifier(image) == sourceIdentity else {
            return
        }
        if let blurred {
            cachedBlurredImage = blurred.value
        }
    }
}

private struct SendablePlatformImage: @unchecked Sendable {
    let value: PlatformImage

    init(_ value: PlatformImage) {
        self.value = value
    }
}

private extension View {
    @ViewBuilder
    func optionalArtworkTransition(id: ObjectIdentifier?, isEnabled: Bool) -> some View {
        if isEnabled {
            self
                .id(id)
                .transition(.opacity)
        } else {
            self
        }
    }
}
