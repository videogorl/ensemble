import SwiftUI

public struct WaveformView: View {
    let progress: Double
    let color: Color
    let heights: [Double]
    
    public init(progress: Double, color: Color, heights: [Double] = []) {
        self.progress = progress
        self.color = color
        self.heights = heights
    }
    
    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                let count = heights.isEmpty ? 40 : heights.count
                let maxHeight = geometry.size.height
                
                ForEach(0..<count, id: \.self) { index in
                    let barProgress = Double(index) / Double(count)
                    let isPlayed = barProgress <= progress
                    let height = heights.isEmpty ? 0.2 : heights[index]
                    
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isPlayed ? color : color.opacity(0.25))
                        .frame(height: max(2, CGFloat(height) * maxHeight))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
