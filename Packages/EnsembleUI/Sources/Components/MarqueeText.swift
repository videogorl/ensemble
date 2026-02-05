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
                    .onAppear {
                        startAnimation()
                    }
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
                    if textWidth > geometry.size.width {
                        LinearGradient(
                            gradient: Gradient(colors: [.clear, .black]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 12)
                        
                        Rectangle().fill(Color.black)
                        
                        LinearGradient(
                            gradient: Gradient(colors: [.black, .clear]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 12)
                    } else {
                        Rectangle().fill(Color.black)
                    }
                }
            )
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
        
        let duration = Double(textWidth) / 30.0 // Adjusted speed
        
        withAnimation(Animation.linear(duration: duration).repeatForever(autoreverses: false)) {
            offset = -(textWidth + 50)
        }
    }
}
