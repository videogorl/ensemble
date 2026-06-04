import EnsembleCore
import SwiftUI

/// Shared card factory for every Now Playing layout.
struct NowPlayingPanelCard: View {
    let page: NowPlayingPanelPage
    private let viewModel: NowPlayingViewModel
    @Binding private var currentPage: Int
    private let isLowPowerMode: Bool
    private let isAlwaysVisible: Bool
    private let showsLyricsTransportControls: Bool

    init(
        page: NowPlayingPanelPage,
        viewModel: NowPlayingViewModel,
        currentPage: Binding<Int>,
        isLowPowerMode: Bool,
        isAlwaysVisible: Bool = false,
        showsLyricsTransportControls: Bool = true
    ) {
        self.page = page
        self.viewModel = viewModel
        self._currentPage = currentPage
        self.isLowPowerMode = isLowPowerMode
        self.isAlwaysVisible = isAlwaysVisible
        self.showsLyricsTransportControls = showsLyricsTransportControls
    }

    var body: some View {
        switch page {
        case .queue:
            QueueCard(
                viewModel: viewModel,
                currentPage: $currentPage,
                isAlwaysVisible: isAlwaysVisible
            )
        case .controls:
            ControlsCard(
                viewModel: viewModel,
                currentPage: $currentPage,
                isAlwaysVisible: isAlwaysVisible
            )
        case .lyrics:
            LyricsCard(
                viewModel: viewModel,
                currentPage: $currentPage,
                isLowPowerMode: isLowPowerMode,
                showsTransportControls: showsLyricsTransportControls
            )
        case .info:
            InfoCard(viewModel: viewModel, currentPage: $currentPage)
        }
    }
}

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
        let page = NowPlayingPanelPage.detailPage(for: currentPage)
        NowPlayingPanelCard(
            page: page,
            viewModel: viewModel,
            currentPage: $currentPage,
            isLowPowerMode: isLowPowerMode,
            isAlwaysVisible: page == .queue && keepsQueueAlwaysVisible,
            showsLyricsTransportControls: showsLyricsTransportControls
        )
    }
}
