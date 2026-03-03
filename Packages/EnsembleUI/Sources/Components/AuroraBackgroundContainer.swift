import SwiftUI
import EnsembleCore

/// Container that places aurora visualization behind content within a tab view.
/// This allows the aurora to be visible within each tab while keeping the tab bar on top.
public struct AuroraBackgroundContainer<Content: View>: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    let content: Content
    
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    public var body: some View {
        ZStack {
            // Aurora behind content (only when enabled)
            if settingsManager.auroraVisualizationEnabled {
                AuroraVisualizationView(
                    playbackService: DependencyContainer.shared.playbackService,
                    accentColor: settingsManager.accentColor.color
                )
                .ignoresSafeArea()
                .zIndex(0)
            }
            
            // Tab content in front
            content
                .auroraBackgroundSupport()
                .zIndex(1)
        }
    }
}
