import EnsembleCore
import SwiftUI

/// Non-interactive Now Playing view shown on an external display via AirPlay screen mirroring.
///
/// This is a variant of `NowPlayingViewportRoot` adapted for TV display:
/// - No dismiss button or segmented picker (no user interaction possible on TV)
/// - Panel selection follows `viewModel.currentPage` from the device automatically
/// - Forces dark color scheme (better for TV viewing)
/// - When nothing is playing, the existing `ControlsCard.emptyStateView` handles the idle state
///
/// The view reuses all existing card components (`ControlsCard`, `QueueCard`, `LyricsCard`,
/// `InfoCard`) and shares the same `NowPlayingViewModel` instance as the main UI so all
/// state (playback, lyrics, queue, panel selection) stays in sync with zero duplicate work.
public struct ExternalDisplayNowPlayingView: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor

    /// Tracks the last detail page (Queue/Lyrics/Info) the user was viewing.
    /// When the user swipes to Controls (page 1) on their device, the external
    /// display keeps showing this panel instead of going blank.
    @State private var lastDetailPage: Int = 0

    public init(viewModel: NowPlayingViewModel) {
        self.viewModel = viewModel
    }

    /// Reference size matching a landscape iPad layout. The card components are designed
    /// for this viewing scale. We lay out at this size and then use `scaleEffect` to fill
    /// the TV, so all fonts, spacing, and artwork scale proportionally.
    private static let referenceSize = CGSize(width: 1024, height: 768)

    public var body: some View {
        GeometryReader { geometry in
            let scale = displayScale(for: geometry.size)

            ZStack {
                backgroundView

                // Lay out at the reference iPad size, then scale up to fill the TV.
                // This ensures all card fonts, spacing, and artwork look proportional
                // on screens of any size (1080p, 4K, etc.).
                contentView
                    .frame(
                        width: geometry.size.width / scale,
                        height: geometry.size.height / scale
                    )
                    .scaleEffect(scale)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
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

    /// Scale factor to fill the TV screen from the reference iPad layout size.
    /// Uses `min` so the content fits entirely on screen without clipping.
    private func displayScale(for screenSize: CGSize) -> CGFloat {
        let scaleX = screenSize.width / Self.referenceSize.width
        let scaleY = screenSize.height / Self.referenceSize.height
        return max(min(scaleX, scaleY), 1.0)
    }
}
