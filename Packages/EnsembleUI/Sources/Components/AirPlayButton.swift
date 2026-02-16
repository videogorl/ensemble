import SwiftUI
import AVKit

#if canImport(UIKit)
import UIKit

/// SwiftUI wrapper for AVRoutePickerView to provide native AirPlay button
public struct AirPlayButton: UIViewRepresentable {
    
    public init() {}
    
    public func makeUIView(context: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView()
        
        // Style the button with white color to match other controls
        routePickerView.tintColor = UIColor.white.withAlphaComponent(0.7)
        routePickerView.activeTintColor = UIColor(Color.accentColor)
        
        // Set priority for layout
        routePickerView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        routePickerView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        
        return routePickerView
    }
    
    public func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        // Update tint colors if needed
        uiView.tintColor = UIColor.white.withAlphaComponent(0.7)
        uiView.activeTintColor = UIColor(Color.accentColor)
    }
}
#else
public struct AirPlayButton: View {
    public init() {}
    public var body: some View {
        EmptyView()
    }
}
#endif
