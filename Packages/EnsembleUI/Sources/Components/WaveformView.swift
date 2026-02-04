import SwiftUI

public struct WaveformView: View {
    let progress: Double
    let color: Color
    let barCount: Int = 40
    
    // Seeded random heights for a consistent look for the same "ratingKey" could be better,
    // but for now we'll use a fixed set of heights that look like a real waveform.
    private let heights: [CGFloat] = [
        0.2, 0.4, 0.3, 0.5, 0.7, 0.4, 0.6, 0.8, 0.9, 0.5,
        0.3, 0.4, 0.6, 0.4, 0.2, 0.5, 0.7, 0.8, 0.6, 0.4,
        0.3, 0.5, 0.4, 0.6, 0.8, 0.9, 0.7, 0.5, 0.3, 0.4,
        0.6, 0.8, 0.7, 0.5, 0.4, 0.3, 0.2, 0.4, 0.5, 0.3
    ]
    
    public init(progress: Double, color: Color) {
        self.progress = progress
        self.color = color
    }
    
    public var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                let barProgress = Double(index) / Double(barCount)
                let isPlayed = barProgress <= progress
                
                RoundedRectangle(cornerRadius: 1)
                    .fill(isPlayed ? color : color.opacity(0.3))
                    .frame(height: heights[index % heights.count] * 30)
            }
        }
        .frame(height: 40)
    }
}
