import SwiftUI

public struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let fontWeight: Font.Weight
    
    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var showLeftFade = false
    
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
        // This base Text sets the height and fills the available width
        Text(text)
            .font(font)
            .fontWeight(fontWeight)
            .lineLimit(1)
            .opacity(0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            self.containerWidth = geometry.size.width
                        }
                        .onChange(of: geometry.size.width) { newWidth in
                            self.containerWidth = newWidth
                        }
                }
            )
            .overlay(
                // Measurement view for textWidth
                Text(text)
                    .font(font)
                    .fontWeight(fontWeight)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(GeometryReader { proxy in
                        Color.clear.onAppear { self.textWidth = proxy.size.width }
                    })
                    .opacity(0)
            )
            .overlay(
                ZStack(alignment: .leading) {
                    if textWidth > containerWidth {
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
                .frame(width: containerWidth > 0 ? containerWidth : nil, alignment: .leading)
                .mask(
                    HStack(spacing: 0) {
                        if textWidth > containerWidth {
                            // Left fade - appears quickly when scrolling starts
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .black.opacity(showLeftFade ? 0 : 1), location: 0),
                                    .init(color: .black, location: 1)
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 24)
                            
                            Rectangle().fill(Color.black)
                            
                            // Right fade - always present when overflowing
                            LinearGradient(
                                gradient: Gradient(colors: [.black, .clear]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 24)
                        } else {
                            Rectangle().fill(Color.black)
                        }
                    }
                )
                , alignment: .leading
            )
            .clipped()
            .id(text)
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
        showLeftFade = false
        
        let duration = Double(textWidth) / 30.0
        let delay = 3.0 // Wait at start
        let waitAtEnd = 2.0 // Wait after finishing scroll before resetting
        
        // Start the sequence after an initial delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Trigger fade in quickly (0.3s) just as we start scrolling
            withAnimation(.easeIn(duration: 0.3)) {
                showLeftFade = true
            }
            
            withAnimation(.linear(duration: duration)) {
                offset = -(textWidth + 50)
            }
            
            // Fade out the mask slightly BEFORE the animation finishes
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, duration - 0.3)) {
                withAnimation(.easeOut(duration: 0.3)) {
                    showLeftFade = false
                }
            }
            
            // Wait for the animation to finish, then handle the pause and reset
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                // Wait for the end-of-cycle pause, then reset and loop
                DispatchQueue.main.asyncAfter(deadline: .now() + waitAtEnd) {
                    // Snap back to start without animation
                    offset = 0
                    // Recursively start again
                    startAnimation()
                }
            }
        }
    }
}
