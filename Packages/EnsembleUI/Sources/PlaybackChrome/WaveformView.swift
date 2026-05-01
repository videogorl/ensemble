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
        GeometryReader { geometry in
            HStack(spacing: EnsembleScaffold.Waveform.barSpacing) {
                let count = heights.isEmpty ? EnsembleScaffold.Waveform.emptyBarCount : heights.count
                let maxHeight = geometry.size.height
                
                ForEach(0..<count, id: \.self) { index in
                    let barProgress = Double(index) / Double(count)
                    let isPlayed = barProgress <= progress
                    let isBuffered = barProgress <= bufferedProgress
                    let height = heights.isEmpty ? EnsembleScaffold.Waveform.emptyBarHeightRatio : heights[index]
                    
                    RoundedRectangle(cornerRadius: EnsembleScaffold.Waveform.barCornerRadius)
                        .fill(barColor(isPlayed: isPlayed, isBuffered: isBuffered))
                        .frame(height: max(EnsembleScaffold.Waveform.minimumBarHeight, CGFloat(height) * maxHeight))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
