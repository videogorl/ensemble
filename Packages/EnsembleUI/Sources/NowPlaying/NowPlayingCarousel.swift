import EnsembleCore
import SwiftUI

enum NowPlayingPanelPage: Int, CaseIterable {
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

    static func detailPage(for currentPage: Int) -> NowPlayingPanelPage {
        if currentPage == NowPlayingPanelPage.info.rawValue {
            return .info
        }
        if currentPage == NowPlayingPanelPage.lyrics.rawValue {
            return .lyrics
        }
        return .queue
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
                ForEach(NowPlayingPanelPage.allCases, id: \.rawValue) { page in
                    NowPlayingPanelCard(
                        page: page,
                        viewModel: viewModel,
                        currentPage: $currentPage,
                        isLowPowerMode: powerStateMonitor.isLowPowerMode
                    )
                    .tag(page.rawValue)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never)) // Hide native page dots
            #endif
            .onChange(of: currentPage) { _ in
                markNowPlayingInteraction()
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

    private func markNowPlayingInteraction() {
        let scheduler = DependencyContainer.shared.foregroundWorkScheduler
        scheduler.beginInteraction(.nowPlayingInteractive)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            scheduler.endInteraction(.nowPlayingInteractive)
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
