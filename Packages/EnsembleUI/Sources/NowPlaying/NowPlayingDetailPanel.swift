import EnsembleCore
import SwiftUI

/// Shared Queue/Lyrics/Info renderer for Now Playing surfaces that show one detail panel at a time.
struct NowPlayingDetailPanel: View {
    private let viewModel: NowPlayingViewModel
    @Binding private var currentPage: Int
    private let isLowPowerMode: Bool
    private let showsLyricsTransportControls: Bool
    private let keepsQueueAlwaysVisible: Bool

    init(
        viewModel: NowPlayingViewModel,
        currentPage: Binding<Int>,
        isLowPowerMode: Bool,
        showsLyricsTransportControls: Bool = true,
        keepsQueueAlwaysVisible: Bool = false
    ) {
        self.viewModel = viewModel
        self._currentPage = currentPage
        self.isLowPowerMode = isLowPowerMode
        self.showsLyricsTransportControls = showsLyricsTransportControls
        self.keepsQueueAlwaysVisible = keepsQueueAlwaysVisible
    }

    var body: some View {
        Group {
            if currentPage == NowPlayingPanelPage.info.rawValue {
                InfoCard(viewModel: viewModel, currentPage: $currentPage)
            } else if currentPage == NowPlayingPanelPage.lyrics.rawValue {
                LyricsCard(
                    viewModel: viewModel,
                    currentPage: $currentPage,
                    isLowPowerMode: isLowPowerMode,
                    showsTransportControls: showsLyricsTransportControls
                )
            } else {
                QueueCard(
                    viewModel: viewModel,
                    currentPage: $currentPage,
                    isAlwaysVisible: keepsQueueAlwaysVisible
                )
            }
        }
    }
}
