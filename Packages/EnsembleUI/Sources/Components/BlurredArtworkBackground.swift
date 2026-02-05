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
    
    public init(
        image: UIImage?,
        blurRadius: CGFloat = 80,
        contrast: Double = 1.7,
        saturation: Double = 1.9,
        brightness: Double = 0.1,
        opacity: Double = 1.0,
        topDimming: Double = 0.1,
        bottomDimming: Double = 0.4
    ) {
        self.image = image
        self.blurRadius = blurRadius
        self.contrast = contrast
        self.saturation = saturation
        self.brightness = brightness
        self.opacity = opacity
        self.topDimming = topDimming
        self.bottomDimming = bottomDimming
    }
    
    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = image {
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
                        colors: [
                            .black.opacity(topDimming),
                            .black.opacity(bottomDimming)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    Color.black
                }
            }
            .clipped()
        }
        .ignoresSafeArea()
    }
}
