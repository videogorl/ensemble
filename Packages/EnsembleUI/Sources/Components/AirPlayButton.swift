import SwiftUI
import AVKit
import EnsembleCore

#if canImport(UIKit)
import UIKit

/// SwiftUI wrapper for AVRoutePickerView to provide native AirPlay button
public struct AirPlayButton: UIViewRepresentable {
    
    public init() {}
    
    public func makeUIView(context: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView()
        updateLook(routePickerView)
        
        // Set priority for layout
        routePickerView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        routePickerView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        
        return routePickerView
    }
    
    public func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        updateLook(uiView)
    }
    
    private func updateLook(_ view: AVRoutePickerView) {
        // Use semantic label color (adapts to light/dark) to match .primary.opacity(0.7)
        view.tintColor = UIColor.label.withAlphaComponent(0.7)
        
        // Use user-selected accent color from SettingsManager
        let accentColor = DependencyContainer.shared.settingsManager.accentColor.color
        view.activeTintColor = UIColor(accentColor)
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
