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

    private var animationKey: AnimationKey {
        AnimationKey(text: text, textWidth: textWidth, containerWidth: containerWidth)
    }

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
            .opacity(EnsembleScaffold.Marquee.measurementOpacity)
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
                    .opacity(EnsembleScaffold.Marquee.measurementOpacity)
            )
            .overlay(
                ZStack(alignment: .leading) {
                    if textWidth > containerWidth {
                        // Scrolling text
                        HStack(spacing: EnsembleScaffold.Marquee.duplicateTextSpacing) {
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
                        .task(id: animationKey) {
                            await runAnimation(
                                textWidth: textWidth,
                                containerWidth: containerWidth
                            )
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
                    HStack(spacing: EnsembleDesign.Spacing.none) {
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
                            .frame(width: EnsembleScaffold.Marquee.fadeWidth)
                            
                            Rectangle().fill(Color.black)
                            
                            // Right fade - always present when overflowing
                            LinearGradient(
                                gradient: Gradient(colors: [.black, .clear]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: EnsembleScaffold.Marquee.fadeWidth)
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

    @MainActor
    private func runAnimation(textWidth: CGFloat, containerWidth: CGFloat) async {
        guard textWidth > containerWidth else { return }

        let duration = Double(textWidth) / 30.0
        let delay = 3.0 // Wait at start
        let waitAtEnd = 2.0 // Wait after finishing scroll before resetting

        while !Task.isCancelled {
            offset = 0
            showLeftFade = false

            guard await sleep(seconds: delay) else { return }

            withAnimation(.easeIn(duration: 0.3)) {
                showLeftFade = true
            }

            withAnimation(.linear(duration: duration)) {
                offset = -(textWidth + 50)
            }

            // Fade out the mask slightly before the scroll animation finishes.
            let fadeOutDelay = max(0, duration - 0.3)
            guard await sleep(seconds: fadeOutDelay) else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                showLeftFade = false
            }

            let remainingScroll = max(0, duration - fadeOutDelay)
            guard await sleep(seconds: remainingScroll) else { return }
            guard await sleep(seconds: waitAtEnd) else { return }

            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                offset = 0
            }
        }
    }

    private func sleep(seconds: Double) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private struct AnimationKey: Equatable {
        let text: String
        let textWidth: CGFloat
        let containerWidth: CGFloat
    }
}
