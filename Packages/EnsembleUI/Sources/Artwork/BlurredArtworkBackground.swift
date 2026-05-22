import EnsembleCore
import SwiftUI

/// A background view that uses a heavily blurred version of artwork.
/// When `preBlurredImage` is provided, it is displayed directly without live
/// contrast/saturation/brightness/blur modifiers — saving 4 GPU render passes
/// on every SwiftUI body evaluation.
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
    }
    
    private var content: some View {
        GeometryReader { geometry in
            ZStack {
                // Guard against zero-sized geometry during layout/animation passes
                // to avoid QuartzCore "Failed to create WxH image slot" errors.
                //
                // When a pre-blurred image is available, display it directly without
                // live contrast/saturation/brightness/blur — those effects are already
                // baked in, saving 4 GPU render passes per body evaluation.
                let displayImage = preBlurredImage ?? image
                let isPreBlurred = preBlurredImage != nil

                if let displayImage = displayImage, geometry.size.width > 0, geometry.size.height > 0 {
                    #if os(macOS)
                    // Opaque fill behind the blur — macOS .blur() doesn't support
                    // the opaque: parameter, so edges become semi-transparent.
                    // This prevents the window background from showing through.
                    if !isPreBlurred {
                        overlayColor
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }

                    Image(nsImage: displayImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .if(!isPreBlurred) { view in
                            view.contrast(contrast)
                                .saturation(saturation)
                                .brightness(brightness)
                                .blur(radius: blurRadius)
                        }
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
                        .if(!isPreBlurred) { view in
                            view.contrast(contrast)
                                .saturation(saturation)
                                .brightness(brightness)
                                .blur(radius: blurRadius, opaque: true)
                        }
                        .opacity(opacity)
                        .optionalArtworkTransition(
                            id: image.map(ObjectIdentifier.init),
                            isEnabled: animatesImageChanges
                        )
                    #endif

                    // Saturation gradient (desaturates bottom slightly)
                    LinearGradient(
                        colors: [.clear, .gray.opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.saturation)

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
