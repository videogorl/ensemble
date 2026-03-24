import SwiftUI

/// A background view that uses a heavily blurred version of artwork
public struct BlurredArtworkBackground: View {
    let image: UIImage?
    let blurRadius: CGFloat
    let contrast: Double
    let saturation: Double
    let brightness: Double
    let opacity: Double
    let topDimming: Double
    let bottomDimming: Double
    let shouldIgnoreSafeArea: Bool
    let overlayColor: Color
    
    public init(
        image: UIImage?,
        blurRadius: CGFloat = 80,
        contrast: Double = 2.0,
        saturation: Double = 1.9,
        brightness: Double = -0.05,
        opacity: Double = 1.0,
        topDimming: Double = 0.1,
        bottomDimming: Double = 0.5,
        shouldIgnoreSafeArea: Bool = true,
        overlayColor: Color = .black
    ) {
        self.image = image
        self.blurRadius = blurRadius
        self.contrast = contrast
        self.saturation = saturation
        self.brightness = brightness
        self.opacity = opacity
        self.topDimming = topDimming
        self.bottomDimming = bottomDimming
        self.shouldIgnoreSafeArea = shouldIgnoreSafeArea
        self.overlayColor = overlayColor
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
                // Use a ZStack with .id() and .transition(.opacity) to ensure a smooth cross-fade
                // when the image changes. DO NOT REMOVE THIS - it prevents jarring swaps.
                // Guard against zero-sized geometry during layout/animation passes
                // to avoid QuartzCore "Failed to create WxH image slot" errors.
                if let image = image, geometry.size.width > 0, geometry.size.height > 0 {
                    #if os(macOS)
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .blur(radius: blurRadius)
                        .contrast(contrast)
                        .saturation(saturation)
                        .brightness(brightness)
                        .opacity(opacity)
                        .id(image)
                        .transition(.opacity)
                    #else
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .blur(radius: blurRadius, opaque: true)
                        .contrast(contrast)
                        .saturation(saturation)
                        .brightness(brightness)
                        .opacity(opacity)
                        .id(image)
                        .transition(.opacity)
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
