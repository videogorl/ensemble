import SwiftUI
import EnsembleCore

/// Container that places aurora visualization behind content within a tab view.
/// This allows the aurora to be visible within each tab while keeping the tab bar on top.
public struct AuroraBackgroundContainer<Content: View>: View {
    let playbackService: PlaybackServiceProtocol
    let accentColor: Color
    let isEnabled: Bool
    let content: Content
    
    public init(
        playbackService: PlaybackServiceProtocol,
        accentColor: Color,
        isEnabled: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.playbackService = playbackService
        self.accentColor = accentColor
        self.isEnabled = isEnabled
        self.content = content()
    }
    
    public var body: some View {
        ZStack {
            // Aurora behind content (only when enabled)
            if isEnabled {
                AuroraVisualizationView(
                    playbackService: playbackService,
                    accentColor: accentColor
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
