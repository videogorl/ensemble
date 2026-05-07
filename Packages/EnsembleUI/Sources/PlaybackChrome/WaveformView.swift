import SwiftUI

public struct WaveformView: View {
    let progress: Double
    let bufferedProgress: Double
    let color: Color
    let heights: [Double]
    
    public init(progress: Double, bufferedProgress: Double = 0, color: Color, heights: [Double] = []) {
        self.progress = progress
        self.bufferedProgress = bufferedProgress
        self.color = color
        self.heights = heights
    }
    
    public var body: some View {
        Canvas { context, size in
            drawWaveform(context: context, size: size)
        }
    }

    /// Draw bars in one render pass so progress ticks don't rebuild a SwiftUI
    /// shape tree for every waveform sample.
    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        let count = heights.isEmpty ? EnsembleScaffold.Waveform.emptyBarCount : heights.count
        guard count > 0, size.width > 0, size.height > 0 else { return }

        let spacing = EnsembleScaffold.Waveform.barSpacing
        let totalSpacing = CGFloat(max(0, count - 1)) * spacing
        let barWidth = max(1, (size.width - totalSpacing) / CGFloat(count))
        let maxHeight = size.height

        for index in 0..<count {
            let barProgress = Double(index) / Double(count)
            let isPlayed = barProgress <= progress
            let isBuffered = barProgress <= bufferedProgress
            let height = heights.isEmpty ? EnsembleScaffold.Waveform.emptyBarHeightRatio : heights[index]
            let barHeight = max(
                EnsembleScaffold.Waveform.minimumBarHeight,
                CGFloat(height) * maxHeight
            )
            let x = CGFloat(index) * (barWidth + spacing)
            let y = (maxHeight - barHeight) / 2
            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let cornerRadius = min(
                EnsembleScaffold.Waveform.barCornerRadius,
                barWidth / 2,
                barHeight / 2
            )

            context.fill(
                Path(roundedRect: rect, cornerRadius: cornerRadius),
                with: .color(barColor(isPlayed: isPlayed, isBuffered: isBuffered))
            )
        }
    }

    private func barColor(isPlayed: Bool, isBuffered: Bool) -> Color {
        if isPlayed {
            return color
        }

        if isBuffered {
            return color.opacity(EnsembleScaffold.Waveform.bufferedOpacity)
        }

        return color.opacity(EnsembleScaffold.Waveform.idleOpacity)
    }
}
