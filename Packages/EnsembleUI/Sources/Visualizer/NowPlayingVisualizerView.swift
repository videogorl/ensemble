import EnsembleCore
import MetalKit
import SwiftUI

/// Whether Now Playing shows the visualizer instead of its artwork backdrop.
enum NowPlayingVisualizer {
    @MainActor
    static func isShowing(settings: SettingsManager, track: Track?) -> Bool {
        settings.visualizerEnabled
            && track?.sourceCapabilities.supportsWaveform == true
            && isRendererAvailable
    }

    private static var isRendererAvailable: Bool {
        #if canImport(MetalKit)
        return VisualizerMetalRenderer.isAvailable
        #else
        return false
        #endif
    }
}

/// Keeps Now Playing text legible over the dark visualizer in light mode.
struct NowPlayingVisualizerColorScheme: ViewModifier {
    let playbackProjection: NowPlayingPlaybackProjection
    @Environment(DependencyContainer.self) private var dependencies
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let showsVisualizer = NowPlayingVisualizer.isShowing(
            settings: dependencies.settingsManager,
            track: playbackProjection.currentTrack
        )
        content.environment(\.colorScheme, showsVisualizer ? .dark : colorScheme)
    }
}

/// Full-screen visualizer driven by the playback engine's live output.
/// Audio capture runs only while this view is on screen in an active scene.
struct NowPlayingVisualizerView: View {
    let style: VisualizerStyle
    let isPlaying: Bool
    let isLowPowerMode: Bool
    let accentColor: Color

    @Environment(\.scenePhase) private var scenePhase
    @State private var readerID = UUID()
    @State private var isMounted = false
    @Environment(DependencyContainer.self) private var dependencies
    private var feed: LiveAudioFeed { dependencies.playbackService.liveAudioFeed }

    var body: some View {
        Surface(
            feed: feed,
            style: style,
            accentColor: accentColor,
            framesPerSecond: isLowPowerMode ? 30 : 60,
            isPaused: !isPlaying || scenePhase != .active
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            isMounted = true
            updateReader()
        }
        .onDisappear {
            isMounted = false
            updateReader()
        }
        .onChange(of: scenePhase) { _, _ in
            updateReader()
        }
    }

    private func updateReader() {
        feed.setReader(readerID, isActive: isMounted && scenePhase == .active)
    }
}

#if canImport(UIKit)
private struct Surface: UIViewRepresentable {
    let feed: LiveAudioFeed
    let style: VisualizerStyle
    let accentColor: Color
    let framesPerSecond: Int
    let isPaused: Bool

    func makeCoordinator() -> VisualizerMetalRenderer {
        VisualizerMetalRenderer(feed: feed)
    }

    func makeUIView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(
            view: view,
            style: style,
            accentColor: accentColor,
            framesPerSecond: framesPerSecond,
            isPaused: isPaused
        )
    }
}
#elseif canImport(AppKit)
private struct Surface: NSViewRepresentable {
    let feed: LiveAudioFeed
    let style: VisualizerStyle
    let accentColor: Color
    let framesPerSecond: Int
    let isPaused: Bool

    func makeCoordinator() -> VisualizerMetalRenderer {
        VisualizerMetalRenderer(feed: feed)
    }

    func makeNSView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(
            view: view,
            style: style,
            accentColor: accentColor,
            framesPerSecond: framesPerSecond,
            isPaused: isPaused
        )
    }
}
#endif
