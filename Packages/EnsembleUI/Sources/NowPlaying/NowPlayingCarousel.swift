import EnsembleCore
import SwiftUI

enum NowPlayingPanelPage: Int {
    case queue = 0
    case controls = 1
    case lyrics = 2
    case info = 3

    func isActive(currentPage: Int) -> Bool {
        currentPage == rawValue
    }

    /// Keep the selected and neighboring cards rendered so `.page` swipes reveal
    /// complete panels before SwiftUI commits the new selection at the midpoint.
    func shouldRenderContent(currentPage: Int, isAlwaysVisible: Bool = false) -> Bool {
        isAlwaysVisible || abs(currentPage - rawValue) <= 1
    }
}

/// Horizontal paging carousel managing four cards: Queue, Controls, Lyrics, Info
/// Opens to Controls by default
public struct NowPlayingCarousel: View {
    let viewModel: NowPlayingViewModel
    @Binding var currentPage: Int
    @ObservedObject private var lyricsProjection: NowPlayingLyricsProjection
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor

    public init(viewModel: NowPlayingViewModel, currentPage: Binding<Int>) {
        self.viewModel = viewModel
        self._currentPage = currentPage
        self._lyricsProjection = ObservedObject(wrappedValue: viewModel.lyricsProjection)
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $currentPage) {
                // Page 0: Queue (swipe left from center)
                QueueCard(viewModel: viewModel, currentPage: $currentPage)
                    .tag(0)

                // Page 1: Controls (center, default)
                ControlsCard(viewModel: viewModel, currentPage: $currentPage)
                    .tag(1)

                // Page 2: Lyrics (swipe right from center)
                LyricsCard(viewModel: viewModel, currentPage: $currentPage, isLowPowerMode: powerStateMonitor.isLowPowerMode)
                    .tag(2)

                // Page 3: Info (far right)
                InfoCard(viewModel: viewModel, currentPage: $currentPage)
                    .tag(3)
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never)) // Hide native page dots
            #endif
            .onChange(of: currentPage) { _ in
                handlePageChange()
            }

            // Fixed page indicator overlay — lyrics icon reflects availability
            PageIndicator(
                currentPage: $currentPage,
                lyricsAvailable: lyricsProjection.lyricsState.isAvailable
            )
            .padding(.vertical, EnsembleScaffold.NowPlaying.PageIndicator.verticalPadding)
        }
    }

    // MARK: - Helpers

    private func handlePageChange() {
        // Fire haptic feedback on page change
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }
}
