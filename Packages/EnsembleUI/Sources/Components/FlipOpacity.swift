import SwiftUI

/// Modifier that toggles opacity based on 3D rotation angle
/// to simulate backface culling (hiding the view when it flips away)
struct FlipOpacity: AnimatableModifier {
    var angle: Double
    let type: FlipType
    
    enum FlipType {
        case front
        case back
    }
    
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    
    func body(content: Content) -> some View {
        // Front view is visible from 0 to 90, and 270 to 360
        // Back view is visible from 90 to 270
        let normalizedAngle = angle.truncatingRemainder(dividingBy: 360)
        let isFrontVisible = normalizedAngle < 90 || normalizedAngle > 270
        
        switch type {
        case .front:
            return content
                .opacity(isFrontVisible ? 1 : 0)
                .accessibilityHidden(!isFrontVisible)
        case .back:
            return content
                .opacity(isFrontVisible ? 0 : 1)
                .accessibilityHidden(isFrontVisible)
        }
    }
}

extension View {
    func flipOpacity(angle: Double, type: FlipOpacity.FlipType) -> some View {
        self.modifier(FlipOpacity(angle: angle, type: type))
    }
}
