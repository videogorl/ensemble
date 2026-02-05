import SwiftUI

public struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let fontWeight: Font.Weight
    
    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    
    public init(
        text: String,
        font: Font = .body,
        color: Color = .primary,
        fontWeight: Font.Weight = .regular
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.fontWeight = fontWeight
    }
    
    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background measurement text
                Text(text)
                    .font(font)
                    .fontWeight(fontWeight)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(GeometryReader { textGeometry in
                        Color.clear.onAppear {
                            self.textWidth = textGeometry.size.width
                            self.containerWidth = geometry.size.width
                            startAnimation()
                        }
                    })
                    .opacity(0) // Hide the measurement text
                
                if textWidth > geometry.size.width {
                    // Scrolling text
                    HStack(spacing: 50) {
                        Text(text)
                            .font(font)
                            .fontWeight(fontWeight)
                            .foregroundColor(color)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        
                        Text(text)
                            .font(font)
                            .fontWeight(fontWeight)
                            .foregroundColor(color)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .offset(x: offset)
                } else {
                    // Static text
                    Text(text)
                        .font(font)
                        .fontWeight(fontWeight)
                        .foregroundColor(color)
                        .lineLimit(1)
                }
            }
            .mask(
                HStack(spacing: 0) {
                    // Left fade - only when actually offset
                    if textWidth > geometry.size.width && offset < 0 {
                        LinearGradient(
                            gradient: Gradient(colors: [.clear, .black]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 16)
                    }
                    
                    Rectangle().fill(Color.black)
                    
                    // Right fade - only when text is long
                    if textWidth > geometry.size.width {
                        LinearGradient(
                            gradient: Gradient(colors: [.black, .clear]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 16)
                    }
                }
            )
            .id(text) // Force view reset when text changes
        }
        .frame(height: fontHeight)
    }
    
    private var fontHeight: CGFloat {
        // Approximate height based on font
        #if os(iOS)
        return UIFont.preferredFont(forTextStyle: .body).lineHeight * 1.5
        #else
        return 24
        #endif
    }
    
    private func startAnimation() {
        guard textWidth > containerWidth else { return }
        
        // Reset state
        offset = 0
        
        let duration = Double(textWidth) / 30.0
        let delay = 3.0 // Wait at start
        let waitAtEnd = 2.0 // Wait after finishing scroll before resetting
        
        // Start the sequence after an initial delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.linear(duration: duration)) {
                offset = -(textWidth + 50)
            }
            
            // Wait for duration + waitAtEnd, then reset and loop
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + waitAtEnd) {
                // Snap back to start without animation
                offset = 0
                // Recursively start again
                startAnimation()
            }
        }
    }
}
