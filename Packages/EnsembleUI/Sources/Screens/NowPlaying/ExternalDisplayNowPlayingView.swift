import EnsembleCore
import SwiftUI

/// Non-interactive Now Playing view shown on an external display via AirPlay screen mirroring.
///
/// This wraps the same wide Now Playing layout used by iPad, adapted for TV display:
/// - Panel selection follows `viewModel.currentPage` from the device automatically
/// - Forces dark color scheme (better for TV viewing)
/// - When nothing is playing, the existing `ControlsCard.emptyStateView` handles the idle state
/// - Content is constrained to a 4:3 aspect ratio so panels don't stretch too wide on 16:9 TVs
/// - Uses a reference iPad layout (1024×768) scaled up to the TV via `scaleEffect`
///
/// The view shares the same `NowPlayingViewModel` instance as the main UI so playback,
/// lyrics, queue, and panel selection stay in sync with zero duplicate work.
///
/// ## Known limitation
///
/// SwiftUI renders Metal drawables at `UIScreen.scale` (1x for AirPlay TVs).
/// `scaleEffect` scales the rendered texture, so some elements with compositing
/// boundaries (MarqueeText masks, conditional ZStacks) may appear slightly soft.
/// This is a SwiftUI platform limitation — UIKit-rendered elements (like
/// QueueTableView rows) and images render at full resolution.
public struct ExternalDisplayNowPlayingView: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager

    public init(viewModel: NowPlayingViewModel) {
        self.viewModel = viewModel
    }

    /// Reference size matching a landscape iPad layout. The card components are
    /// designed for this viewing scale. We lay out at this size and use `scaleEffect`
    /// to fill the 4:3 container.
    private static let referenceSize = CGSize(
        width: EnsembleScaffold.NowPlaying.viewportContentMaxWidth,
        height: EnsembleScaffold.NowPlaying.viewportContentMaxHeight
    )

    public var body: some View {
        GeometryReader { geometry in
            let container = containerSize(for: geometry.size)
            let scale = layoutScale(for: container)

            ZStack {
                // Background fills the entire TV screen (edge-to-edge blur)
                backgroundView(activeContentMaxWidth: container.width)

                // Content constrained to 4:3, laid out at iPad reference size
                // then scaled up proportionally via scaleEffect.
                NowPlayingWidePanelLayout(
                    viewModel: viewModel,
                    currentPage: $viewModel.currentPage
                )
                    .frame(
                        width: container.width / scale,
                        height: container.height / scale
                    )
                    .scaleEffect(scale)
                    .frame(width: container.width, height: container.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accentColor(settingsManager.accentColor.color)
        .preferredColorScheme(.dark)
    }

    // MARK: - Background

    private func backgroundView(activeContentMaxWidth: CGFloat) -> some View {
        ZStack {
            BlurredArtworkBackground(
                image: viewModel.artworkImage,
                preBlurredImage: viewModel.blurredArtworkImage,
                overlayColor: .black
            )
            .animation(.easeInOut(duration: 0.8), value: viewModel.artworkImage)

            // Dark overlay for readability on TV
            Color.black.opacity(EnsembleScaffold.NowPlaying.backgroundDarkOverlayOpacity)
                .allowsHitTesting(false)

            if settingsManager.auroraVisualizationEnabled {
                AuroraVisualizationView(
                    playbackService: DependencyContainer.shared.playbackService,
                    consumer: .externalDisplay,
                    accentColor: settingsManager.accentColor.color,
                    isLowPowerMode: powerStateMonitor.isLowPowerMode,
                    activeContentMaxWidth: activeContentMaxWidth
                )
                .allowsHitTesting(false)
                .opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Layout

    /// Computes the largest 4:3 box that fits within the TV screen.
    /// This keeps controls and panels at iPad-like proportions instead of
    /// stretching across the full 16:9 (or wider) TV width.
    private func containerSize(for screenSize: CGSize) -> CGSize {
        let targetRatio = EnsembleScaffold.NowPlaying.externalDisplayAspectRatio
        let screenRatio = screenSize.width / screenSize.height

        if screenRatio > targetRatio {
            // TV is wider than 4:3 — constrain width, use full height
            let height = screenSize.height
            let width = height * targetRatio
            return CGSize(width: width, height: height)
        } else {
            // TV is narrower than 4:3 (unlikely) — use full width, constrain height
            let width = screenSize.width
            let height = width / targetRatio
            return CGSize(width: width, height: height)
        }
    }

    /// Scale factor from reference iPad size to 4:3 container.
    /// Uses `min` so the content fits entirely without clipping.
    private func layoutScale(for container: CGSize) -> CGFloat {
        let scaleX = container.width / Self.referenceSize.width
        let scaleY = container.height / Self.referenceSize.height
        return max(min(scaleX, scaleY), 1.0)
    }
}
