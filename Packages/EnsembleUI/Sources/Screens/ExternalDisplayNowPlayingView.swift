import EnsembleCore
import SwiftUI

/// Non-interactive Now Playing view shown on an external display via AirPlay screen mirroring.
///
/// This is a variant of `NowPlayingViewportRoot` adapted for TV display:
/// - No dismiss button or segmented picker (no user interaction possible on TV)
/// - Panel selection follows `viewModel.currentPage` from the device automatically
/// - Forces dark color scheme (better for TV viewing)
/// - When nothing is playing, the existing `ControlsCard.emptyStateView` handles the idle state
/// - Content is constrained to a 4:3 aspect ratio so panels don't stretch too wide on 16:9 TVs
/// - Uses a reference iPad layout (1024×768) scaled up to the TV, with high-DPI rendering
///
/// The view reuses all existing card components (`ControlsCard`, `QueueCard`, `LyricsCard`,
/// `InfoCard`) and shares the same `NowPlayingViewModel` instance as the main UI so all
/// state (playback, lyrics, queue, panel selection) stays in sync with zero duplicate work.
public struct ExternalDisplayNowPlayingView: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager

    /// Tracks the last detail page (Queue/Lyrics/Info) the user was viewing.
    /// When the user swipes to Controls (page 1) on their device, the external
    /// display keeps showing this panel instead of going blank.
    @State private var lastDetailPage: Int = 0

    public init(viewModel: NowPlayingViewModel) {
        self.viewModel = viewModel
    }

    /// Reference size matching a landscape iPad layout. The card components are
    /// designed for this viewing scale. We lay out at this size and use `scaleEffect`
    /// to fill the 4:3 container. The hosting HighDPIContainerController overrides
    /// UITraitCollection.displayScale for crisp text rendering at TV resolution.
    private static let referenceSize = CGSize(width: 1024, height: 768)

    public var body: some View {
        GeometryReader { geometry in
            let container = containerSize(for: geometry.size)
            let scale = layoutScale(for: container)

            ZStack {
                // Background fills the entire TV screen (edge-to-edge blur)
                backgroundView

                // Content constrained to 4:3, laid out at iPad reference size
                // then scaled up proportionally. The HighDPIContainerController
                // overrides UITraitCollection.displayScale so SwiftUI renders
                // text/symbols at high pixel density before the scale transform.
                // DO NOT set .environment(\.displayScale) here — the trait
                // collection override provides the correct (higher) value, and
                // an explicit environment override would take precedence and
                // lower the effective scale.
                contentView
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
        .onAppear {
            // Viewport layout always shows ControlsCard on the left.
            // Carousel page 1 (Controls) has no panel equivalent in this layout —
            // seed lastDetailPage so the right panel shows Queue by default.
            if viewModel.currentPage == 1 {
                lastDetailPage = 0
            } else {
                lastDetailPage = viewModel.currentPage
            }
        }
        .onChange(of: viewModel.currentPage) { newPage in
            // When the user navigates to a detail panel (Queue/Lyrics/Info),
            // remember it. When they swipe to Controls (page 1), we keep
            // showing the last detail panel on the external display.
            if newPage != 1 {
                lastDetailPage = newPage
            }
        }
    }

    // MARK: - Content

    /// Two-column Now Playing layout (controls + detail panel).
    private var contentView: some View {
        HStack(alignment: .top, spacing: 24) {
            // Left panel: artwork, scrubber, playback controls (always visible)
            ControlsCard(viewModel: viewModel, currentPage: $viewModel.currentPage)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .topLeading)

            // Right panel: follows whatever the user has selected on their device
            detailPanel
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 32)
    }

    // MARK: - Detail Panel

    /// The page index used for the right detail panel.
    /// When the user is on Controls (page 1) on their device, we show the last
    /// detail panel they were viewing instead of a blank/default panel.
    private var effectiveDetailPage: Int {
        viewModel.currentPage == 1 ? lastDetailPage : viewModel.currentPage
    }

    /// Binding that tells detail cards they're "visible" even when the device
    /// is on the Controls page (page 1). Cards gate their content behind an
    /// `isVisible` check (`currentPage == myPage`); by passing
    /// `effectiveDetailPage` as the read value, the card sees its own page
    /// index and renders content. Writes go through to `viewModel.currentPage`.
    private var effectivePageBinding: Binding<Int> {
        Binding(
            get: { effectiveDetailPage },
            set: { viewModel.currentPage = $0 }
        )
    }

    /// Switches the right panel based on the device's current page selection.
    /// When the device is on Controls (page 1), keeps the last detail panel visible.
    /// NOTE: If you add a new card/panel to NowPlayingViewportRoot or NowPlayingCarousel,
    /// you MUST also add it here so it appears on the external display.
    @ViewBuilder
    private var detailPanel: some View {
        if effectiveDetailPage == 3 {
            InfoCard(viewModel: viewModel, currentPage: effectivePageBinding)
        } else if effectiveDetailPage == 2 {
            LyricsCard(
                viewModel: viewModel,
                currentPage: effectivePageBinding,
                isLowPowerMode: powerStateMonitor.isLowPowerMode
            )
        } else {
            QueueCard(viewModel: viewModel, currentPage: effectivePageBinding)
        }
    }

    // MARK: - Background

    private var backgroundView: some View {
        ZStack {
            BlurredArtworkBackground(
                image: viewModel.artworkImage,
                overlayColor: .black
            )
            .animation(.easeInOut(duration: 0.8), value: viewModel.artworkImage)

            // Dark overlay for readability on TV
            Color.black.opacity(0.45)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    // MARK: - Layout

    /// Computes the largest 4:3 box that fits within the TV screen.
    /// This keeps controls and panels at iPad-like proportions instead of
    /// stretching across the full 16:9 (or wider) TV width.
    private func containerSize(for screenSize: CGSize) -> CGSize {
        let targetRatio: CGFloat = 4.0 / 3.0
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
