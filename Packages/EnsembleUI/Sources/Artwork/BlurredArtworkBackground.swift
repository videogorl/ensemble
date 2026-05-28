import EnsembleCore
import SwiftUI

/// A background view that uses a heavily blurred version of artwork.
///
/// The blur is always bitmap-backed. Callers should pass `preBlurredImage` from
/// an artwork resolver so navigation/layout passes do not generate blur work.
public struct BlurredArtworkBackground: View {
    let image: PlatformImage?
    let preBlurredImage: PlatformImage?
    let preBlurredCacheKey: String?
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
    let allowsLiveBlurRender: Bool
    let fadesInDelayedImages: Bool
    @State private var cachedBlurredImage: PlatformImage?
    @State private var cachedBlurredImageIdentity: String?
    @State private var renderedArtworkOpacity: Double
    @State private var sourceStartedWithoutRenderableImage: Bool
    @State private var preparedBlurSourceIdentity: String?

    public init(
        image: PlatformImage?,
        preBlurredImage: PlatformImage? = nil,
        preBlurredCacheKey: String? = nil,
        blurRadius: CGFloat = 80,
        contrast: Double = 2.0,
        saturation: Double = 1.9,
        brightness: Double = -0.05,
        opacity: Double = 1.0,
        topDimming: Double = 0.1,
        bottomDimming: Double = 0.5,
        shouldIgnoreSafeArea: Bool = true,
        overlayColor: Color = .black,
        animatesImageChanges: Bool = true,
        allowsLiveBlurRender: Bool = false,
        fadesInDelayedImages: Bool = false
    ) {
        let sourceIdentity = Self.blurSourceIdentity(
            image: image,
            preBlurredImage: preBlurredImage,
            preBlurredCacheKey: preBlurredCacheKey
        )
        let initialCachedImage = Self.synchronouslyCachedBlurredImage(
            image: image,
            preBlurredImage: preBlurredImage,
            preBlurredCacheKey: preBlurredCacheKey
        )
        self.image = image
        self.preBlurredImage = preBlurredImage
        self.preBlurredCacheKey = preBlurredCacheKey
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
        self.allowsLiveBlurRender = allowsLiveBlurRender
        self.fadesInDelayedImages = fadesInDelayedImages
        self._cachedBlurredImage = State(initialValue: initialCachedImage)
        self._cachedBlurredImageIdentity = State(initialValue: initialCachedImage == nil ? nil : sourceIdentity)
        self._renderedArtworkOpacity = State(initialValue: initialCachedImage == nil && fadesInDelayedImages ? 0 : 1)
        self._sourceStartedWithoutRenderableImage = State(initialValue: initialCachedImage == nil)
        self._preparedBlurSourceIdentity = State(initialValue: sourceIdentity)
    }
    
    public var body: some View {
        Group {
            if shouldIgnoreSafeArea {
                content.ignoresSafeArea()
            } else {
                content
            }
        }
        .onAppear {
            updateRenderedArtworkOpacityForCurrentSource()
        }
        .onChange(of: blurSourceIdentity) { _ in
            updateRenderedArtworkOpacityForCurrentSource()
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
                let displayImage = currentDisplayImage

                if let displayImage = displayImage, geometry.size.width > 0, geometry.size.height > 0 {
                    #if os(macOS)
                    Image(nsImage: displayImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .opacity(opacity * renderedArtworkOpacity)
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
                        .opacity(opacity * renderedArtworkOpacity)
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
        Self.blurSourceIdentity(
            image: image,
            preBlurredImage: preBlurredImage,
            preBlurredCacheKey: preBlurredCacheKey
        )
    }

    private var cachedStableBlurredImage: PlatformImage? {
        guard let preBlurredCacheKey else { return nil }
        return ArtworkBlurRenderer.cachedBlurredImage(forStableKey: preBlurredCacheKey)
    }

    private var currentDisplayImage: PlatformImage? {
        if let preBlurredImage {
            return preBlurredImage
        }
        if cachedBlurredImageIdentity == blurSourceIdentity,
           let cachedBlurredImage {
            return cachedBlurredImage
        }
        return cachedStableBlurredImage
    }

    private var currentSourceHasSynchronousCachedImage: Bool {
        if cachedBlurredImageIdentity == blurSourceIdentity,
           cachedBlurredImage != nil {
            return true
        }
        if cachedStableBlurredImage != nil {
            return true
        }
        if let image,
           ArtworkBlurRenderer.cachedBlurredImage(for: image) != nil {
            return true
        }
        return false
    }

    @MainActor
    private func updateCachedBlurredImage() async {
        let sourceIdentity = blurSourceIdentity

        if let preBlurredImage {
            setCachedBlurredImage(preBlurredImage, identity: sourceIdentity)
            return
        }

        if let cached = cachedStableBlurredImage {
            setCachedBlurredImage(cached, identity: sourceIdentity)
            return
        }

        guard let image else {
            setCachedBlurredImage(nil, identity: sourceIdentity)
            return
        }

        if let cached = ArtworkBlurRenderer.cachedBlurredImage(for: image) {
            setCachedBlurredImage(cached, identity: sourceIdentity)
            return
        }

        guard allowsLiveBlurRender else {
            setCachedBlurredImage(nil, identity: sourceIdentity)
            return
        }

        let imageIdentity = ObjectIdentifier(image)
        let sendableImage = SendablePlatformImage(image)
        let blurred = await Task.detached(priority: .utility) {
            ArtworkBlurRenderer.blurredImage(from: sendableImage.value)
                .map(SendablePlatformImage.init)
        }.value

        guard !Task.isCancelled, ObjectIdentifier(image) == imageIdentity, blurSourceIdentity == sourceIdentity else {
            return
        }
        if let blurred {
            setCachedBlurredImage(blurred.value, identity: sourceIdentity)
        }
    }

    @MainActor
    private func setCachedBlurredImage(_ image: PlatformImage?, identity: String) {
        cachedBlurredImage = image
        cachedBlurredImageIdentity = image == nil ? nil : identity
        updateRenderedArtworkOpacityForCurrentSource()
    }

    @MainActor
    private func updateRenderedArtworkOpacityForCurrentSource() {
        guard fadesInDelayedImages else {
            renderedArtworkOpacity = 1
            sourceStartedWithoutRenderableImage = false
            preparedBlurSourceIdentity = blurSourceIdentity
            return
        }

        let sourceIdentity = blurSourceIdentity
        let sourceChanged = preparedBlurSourceIdentity != sourceIdentity
        let hasDisplayImage = currentDisplayImage != nil

        if sourceChanged {
            preparedBlurSourceIdentity = sourceIdentity
            if !hasDisplayImage {
                sourceStartedWithoutRenderableImage = true
                renderedArtworkOpacity = 0
                return
            }
            if preBlurredImage == nil, currentSourceHasSynchronousCachedImage {
                sourceStartedWithoutRenderableImage = false
                renderedArtworkOpacity = 1
                return
            }
        }

        guard hasDisplayImage else {
            sourceStartedWithoutRenderableImage = true
            renderedArtworkOpacity = 0
            return
        }

        if !sourceStartedWithoutRenderableImage {
            renderedArtworkOpacity = 1
            return
        }

        guard renderedArtworkOpacity == 0 else {
            sourceStartedWithoutRenderableImage = false
            return
        }

        sourceStartedWithoutRenderableImage = false
        withAnimation(.easeInOut(duration: 0.28)) {
            renderedArtworkOpacity = 1
        }
    }

    private static func blurSourceIdentity(
        image: PlatformImage?,
        preBlurredImage: PlatformImage?,
        preBlurredCacheKey: String?
    ) -> String {
        if let preBlurredImage {
            return "pre:\(ObjectIdentifier(preBlurredImage).hashValue)"
        }
        if let preBlurredCacheKey {
            return "stable:\(preBlurredCacheKey)"
        }
        return image.map { "source:\(ObjectIdentifier($0).hashValue)" } ?? "nil"
    }

    private static func synchronouslyCachedBlurredImage(
        image: PlatformImage?,
        preBlurredImage: PlatformImage?,
        preBlurredCacheKey: String?
    ) -> PlatformImage? {
        if let preBlurredImage {
            return preBlurredImage
        }
        if let preBlurredCacheKey,
           let stableImage = ArtworkBlurRenderer.cachedBlurredImage(forStableKey: preBlurredCacheKey) {
            return stableImage
        }
        if let image,
           let cachedImage = ArtworkBlurRenderer.cachedBlurredImage(for: image) {
            return cachedImage
        }
        return nil
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
